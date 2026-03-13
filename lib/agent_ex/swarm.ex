defmodule AgentEx.Swarm do
  @moduledoc """
  Multi-agent orchestration via handoffs — maps to AutoGen's Swarm pattern.

  Agents hand off to each other using transfer tools. The Swarm manages the
  routing: when an agent calls `transfer_to_<name>()`, the conversation
  switches to the target agent.

  ```
                      ┌──────────┐
           handoff    │ Planner  │    handoff
          ┌──────────▶│          │◀──────────┐
          │           └────┬─────┘           │
          │                │ handoff          │
          │                ▼                 │
     ┌────┴─────┐    ┌──────────┐    ┌──────┴────┐
     │  Writer  │    │ Analyst  │    │   News    │
     │          │◀───│          │───▶│  Analyst  │
     └──────────┘    └──────────┘    └───────────┘
  ```

  ## AutoGen equivalent (Python):

      team = Swarm(
          participants=[planner, analyst, writer],
          termination_condition=HandoffTermination(target="user")
      )
      result = await team.run(task="Analyze AAPL")

  ## AgentEx:

      agents = [
        Swarm.Agent.new(name: "planner", system_message: "Route tasks...", handoffs: ["analyst"]),
        Swarm.Agent.new(name: "analyst", system_message: "Analyze...", tools: [lookup], handoffs: ["planner"]),
      ]

      {:ok, result} = Swarm.run(agents, client, messages,
        start: "planner",
        termination: {:handoff, "user"}
      )
  """

  alias AgentEx.{Handoff, Message, ModelClient, Sensing, Tool, ToolAgent}
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
          model_fn: ([Message.t()], [Tool.t()] -> {:ok, Message.t()} | {:error, term()})
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
  """
  @spec run([Agent.t()], ModelClient.t(), [Message.t()], opts()) :: result()
  def run(agents, model_client, messages, opts \\ []) do
    start_name = Keyword.fetch!(opts, :start)
    termination = Keyword.get(opts, :termination, :text_response)
    max_iterations = Keyword.get(opts, :max_iterations, 20)
    intervention = Keyword.get(opts, :intervention, [])
    model_fn = Keyword.get(opts, :model_fn)

    agents_map = Map.new(agents, fn %Agent{name: name} = agent -> {name, agent} end)
    tool_agents = start_tool_agents(agents)

    context = %{
      agents_map: agents_map,
      tool_agents: tool_agents,
      model_client: model_client,
      termination: termination,
      max_iterations: max_iterations,
      intervention: intervention,
      model_fn: model_fn
    }

    case Map.fetch(agents_map, start_name) do
      {:ok, _agent} ->
        Logger.debug("Swarm: starting with agent '#{start_name}'")
        swarm_loop(context, start_name, messages, [], 0)

      :error ->
        {:error, {:unknown_agent, start_name}}
    end
  end

  # -- Internal loop --

  defp swarm_loop(context, current_name, input_messages, generated, iteration) do
    if iteration >= context.max_iterations do
      Logger.warning("Swarm: hit max_iterations (#{context.max_iterations})")
      {:ok, generated, nil}
    else
      agent = Map.fetch!(context.agents_map, current_name)
      tool_agent_pid = Map.fetch!(context.tool_agents, current_name)

      # Build tools: agent's own tools + transfer tools for handoff targets
      all_tools = agent.tools ++ Handoff.transfer_tools(agent.handoffs)
      tools_map = Map.new(all_tools, fn %Tool{name: name} = t -> {name, t} end)

      # Build messages: current agent's system message + input + generated
      full_messages = [Message.system(agent.system_message) | input_messages] ++ generated

      # THINK: Ask the LLM
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

          handle_tool_response(context, current_name, input_messages, new_generated, iteration, tool_calls)

        {:ok, %Message{} = response} ->
          Logger.debug("Swarm: agent '#{current_name}' returned text response")
          {:ok, generated ++ [response], nil}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_tool_response(context, current_name, input_messages, generated, iteration, tool_calls) do
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
      {:ok, pid} = ToolAgent.start_link(tools: all_tools)
      {name, pid}
    end)
  end
end
