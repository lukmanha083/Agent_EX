defmodule AgentEx.Swarm do
  @moduledoc """
  Multi-agent orchestration via handoffs — maps to AutoGen's Swarm pattern.

  Agents hand off to each other using transfer tools. The Swarm manages the
  routing: when an agent calls `transfer_to_<name>()`, the conversation
  switches to the target agent.

  ## Memory integration

  When `:memory` option is provided, each agent in the swarm gets its own
  memory scope. The Swarm automatically:
  1. Starts a working memory session per agent
  2. Injects agent-scoped memory context before each LLM call
  3. Stores each turn in the agent's working memory
  4. Cleans up sessions when the swarm completes

      {:ok, result} = Swarm.run(agents, client, messages,
        start: "planner",
        memory: %{session_id: "swarm-session-1"}
      )

  ## AutoGen equivalent (Python):

      team = Swarm(
          participants=[planner, analyst, writer],
          termination_condition=HandoffTermination(target="user")
      )
      result = await team.run(task="Analyze AAPL")
  """

  alias AgentEx.{Handoff, Memory, Message, ModelClient, Sensing, Tool, ToolAgent}
  alias AgentEx.Handoff.HandoffMessage

  require Logger

  defmodule Agent do
    @moduledoc """
    An agent in a swarm — has a name, system message, tools, and handoff targets.

    Maps to AutoGen's `AssistantAgent` with `handoffs` parameter.
    """
    @enforce_keys [:name, :system_message]
    defstruct [:name, :system_message, tools: [], handoffs: []]

    @type t :: %__MODULE__{
            name: String.t(),
            system_message: String.t(),
            tools: [AgentEx.Tool.t()],
            handoffs: [String.t()]
          }

    def new(opts), do: struct!(__MODULE__, opts)
  end

  @type termination :: {:handoff, String.t()} | :text_response

  @type opts :: [
          start: String.t(),
          termination: termination(),
          max_iterations: pos_integer(),
          intervention: [AgentEx.Intervention.handler()],
          model_fn: ([Message.t()], [Tool.t()] -> {:ok, Message.t()} | {:error, term()}),
          memory: %{session_id: String.t()} | nil
        ]

  @type result :: {:ok, [Message.t()], HandoffMessage.t() | nil} | {:error, term()}

  @doc """
  Run a swarm of agents.

  ## Options
  - `:start` — name of the starting agent (required)
  - `:termination` — `{:handoff, "user"}` to stop when handoff targets a name,
    or `:text_response` to stop on any text response (default)
  - `:max_iterations` — max total iterations across all agents (default: 20)
  - `:intervention` — intervention handlers for tool execution
  - `:model_fn` — override for ModelClient.create (useful for testing)
  - `:memory` — `%{session_id: "..."}` to enable per-agent memory scoping.
    Each agent uses its name as `agent_id`. The session_id is shared so
    agents can operate within the same conversation session.
  """
  @spec run([Agent.t()], ModelClient.t(), [Message.t()], opts()) :: result()
  def run(agents, model_client, messages, opts \\ []) do
    start_name = Keyword.fetch!(opts, :start)
    termination = Keyword.get(opts, :termination, :text_response)
    max_iterations = Keyword.get(opts, :max_iterations, 20)
    intervention = Keyword.get(opts, :intervention, [])
    model_fn = Keyword.get(opts, :model_fn)
    memory_opts = Keyword.get(opts, :memory)

    agents_map = Map.new(agents, fn %Agent{name: name} = agent -> {name, agent} end)
    tool_agents = start_tool_agents(agents)

    # Start memory sessions for each agent if memory is enabled
    if memory_opts do
      start_memory_sessions(agents, memory_opts.session_id)
    end

    context = %{
      agents_map: agents_map,
      tool_agents: tool_agents,
      model_client: model_client,
      termination: termination,
      max_iterations: max_iterations,
      intervention: intervention,
      model_fn: model_fn,
      memory: memory_opts
    }

    result =
      case Map.fetch(agents_map, start_name) do
        {:ok, _agent} ->
          Logger.debug("Swarm: starting with agent '#{start_name}'")
          swarm_loop(context, start_name, messages, [], 0)

        :error ->
          {:error, {:unknown_agent, start_name}}
      end

    # Clean up memory sessions
    if memory_opts do
      stop_memory_sessions(agents, memory_opts.session_id)
    end

    result
  end

  # -- Internal loop --

  defp swarm_loop(context, current_name, input_messages, generated, iteration) do
    if iteration >= context.max_iterations do
      Logger.warning("Swarm: hit max_iterations (#{context.max_iterations})")
      {:ok, generated, nil}
    else
      agent = Map.fetch!(context.agents_map, current_name)
      tool_agent_pid = Map.fetch!(context.tool_agents, current_name)

      all_tools = agent.tools ++ Handoff.transfer_tools(agent.handoffs)
      tools_map = Map.new(all_tools, fn %Tool{name: name} = t -> {name, t} end)

      # Build messages: system message + memory context + input + generated
      base_messages = [Message.system(agent.system_message) | input_messages]

      full_messages =
        maybe_inject_memory(base_messages, current_name, context.memory) ++ generated

      Logger.debug("Swarm: agent '#{current_name}' THINK (iteration #{iteration})")

      case think(context, full_messages, all_tools) do
        {:ok, %Message{tool_calls: tool_calls} = response}
        when is_list(tool_calls) and tool_calls != [] ->
          {:ok, result_message, _observations} =
            Sensing.sense(tool_agent_pid, tool_calls,
              intervention: context.intervention,
              tools_map: tools_map,
              intervention_context: %{iteration: iteration, generated_messages: generated}
            )

          new_generated = generated ++ [response, result_message]

          handle_tool_response(
            context,
            current_name,
            input_messages,
            new_generated,
            iteration,
            tool_calls
          )

        {:ok, %Message{} = response} ->
          Logger.debug("Swarm: agent '#{current_name}' returned text response")
          maybe_store_turn(current_name, response, context.memory)
          {:ok, generated ++ [response], nil}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_tool_response(
         context,
         current_name,
         input_messages,
         generated,
         iteration,
         tool_calls
       ) do
    case Handoff.detect(tool_calls) do
      {:handoff, target_name, _call} ->
        handle_handoff(context, current_name, target_name, input_messages, generated, iteration)

      :none ->
        swarm_loop(context, current_name, input_messages, generated, iteration + 1)
    end
  end

  defp handle_handoff(context, source, target, input_messages, generated, iteration) do
    Logger.debug("Swarm: handoff from '#{source}' to '#{target}'")

    handoff_msg = %HandoffMessage{
      target: target,
      source: source,
      content: "Transferred from #{source} to #{target}"
    }

    case context.termination do
      {:handoff, ^target} ->
        Logger.debug("Swarm: termination — handoff to '#{target}'")
        {:ok, generated, handoff_msg}

      _ when is_map_key(context.agents_map, target) ->
        swarm_loop(context, target, input_messages, generated, iteration + 1)

      _ ->
        {:error, {:unknown_agent, target}}
    end
  end

  # -- Memory helpers --

  defp maybe_inject_memory(messages, _agent_name, nil), do: messages

  defp maybe_inject_memory(messages, agent_name, %{session_id: session_id}) do
    Memory.inject_memory_context(messages, agent_name, session_id)
  end

  defp maybe_store_turn(_agent_name, _response, nil), do: :ok

  defp maybe_store_turn(agent_name, %Message{content: content}, %{session_id: session_id})
       when is_binary(content) and content != "" do
    Memory.add_message(agent_name, session_id, "assistant", content)
  end

  defp maybe_store_turn(_, _, _), do: :ok

  defp start_memory_sessions(agents, session_id) do
    Enum.each(agents, fn %Agent{name: name} ->
      case Memory.start_session(name, session_id) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end)
  end

  defp stop_memory_sessions(agents, session_id) do
    Enum.each(agents, fn %Agent{name: name} ->
      Memory.stop_session(name, session_id)
    end)
  end

  # Dispatch to model_fn override or ModelClient.create
  defp think(%{model_fn: nil} = context, messages, tools) do
    ModelClient.create(context.model_client, messages, tools: tools)
  end

  defp think(%{model_fn: fun}, messages, tools) when is_function(fun, 2) do
    fun.(messages, tools)
  end

  # Start a ToolAgent for each swarm agent (holds own tools + transfer tools)
  defp start_tool_agents(agents) do
    Map.new(agents, fn %Agent{name: name, tools: tools, handoffs: handoffs} ->
      all_tools = tools ++ Handoff.transfer_tools(handoffs)
      {:ok, pid} = ToolAgent.start_link(tools: all_tools, agent_id: name)
      {name, pid}
    end)
  end
end
