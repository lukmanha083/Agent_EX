defmodule AgentEx.ToolCallerLoop do
  @moduledoc """
  The core tool-calling loop — maps to AutoGen's `tool_agent_caller_loop`.

  Orchestrates the Sense-Think-Act cycle between an LLM and a ToolAgent:

  ```
  THINK → LLM decides what it needs         (ModelClient.create)
  SENSE → Intervention + tools gather info   (Sensing.sense)
  THINK → LLM reasons about results         (ModelClient.create)
  ...repeat until LLM returns text...
  ACT   → Final text response                (loop exits)
  ```

  ## Memory integration

  When `:memory` option is provided, the loop automatically:
  1. Builds agent-scoped context from all memory tiers before the first THINK
  2. Stores each conversation turn in working memory

      AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
        memory: %{user_id: uid, project_id: pid, agent_id: "analyst", session_id: "sess-1"}
      )

  ## Intervention pipeline

  Tool calls pass through an intervention pipeline before execution:
  - `:read` tools → auto-approved (like `r--` in Linux)
  - `:write` tools → can be gated by handlers (like `-w-` permissions)
  """

  alias AgentEx.Memory
  alias AgentEx.Memory.ProceduralMemory.Observer
  alias AgentEx.Message
  alias AgentEx.ModelClient
  alias AgentEx.Sensing
  alias AgentEx.Tool

  require Logger

  @type memory_opts :: %{
          user_id: term(),
          project_id: term(),
          agent_id: String.t(),
          session_id: String.t()
        }

  @type opts :: [
          max_iterations: pos_integer(),
          caller_source: String.t(),
          tool_timeout: pos_integer(),
          intervention: [AgentEx.Intervention.handler()],
          memory: memory_opts() | nil,
          model_fn:
            ([Message.t()], [Tool.t()] -> {:ok, Message.t()} | {:error, term()})
            | nil
        ]

  @doc """
  Run the tool-calling loop.

  Returns `{:ok, generated_messages}` where the last message contains
  the final text response from the LLM.

  ## Options
  - `:max_iterations` — max sensing rounds before stopping (default: 10)
  - `:caller_source` — source label for assistant messages (default: "assistant")
  - `:tool_timeout` — per-tool execution timeout in ms (default: 30_000)
  - `:intervention` — list of intervention handlers (modules or functions)
  - `:memory` — `%{user_id: ..., project_id: ..., agent_id: "...", session_id: "..."}`
    to enable per-agent memory. When set, injects memory context before the
    first LLM call and stores each user/assistant turn in working memory.
  - `:model_fn` — override for `ModelClient.create/3`. Signature:
    `(messages, tools) -> {:ok, Message.t()} | {:error, term()}`.
    Useful for testing or wrapping with event broadcasting.
  """
  @spec run(GenServer.server(), ModelClient.t(), [Message.t()], [Tool.t()], opts()) ::
          {:ok, [Message.t()]} | {:error, term()}
  def run(tool_agent, model_client, input_messages, tools, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    caller_source = Keyword.get(opts, :caller_source, "assistant")
    tool_timeout = Keyword.get(opts, :tool_timeout, 30_000)
    intervention = Keyword.get(opts, :intervention, [])
    memory_opts = Keyword.get(opts, :memory)
    model_fn = Keyword.get(opts, :model_fn)

    tools_map = Map.new(tools, fn %Tool{name: name} = tool -> {name, tool} end)

    # Store user messages BEFORE injecting context (avoids re-storing history)
    maybe_store_user_messages(input_messages, memory_opts)

    # Inject agent-scoped context (Tier 2/3/KG system msgs + Tier 1 conversation)
    input_messages = maybe_inject_memory_context(input_messages, memory_opts)

    context = %{
      tool_agent: tool_agent,
      model_client: model_client,
      model_fn: model_fn,
      input_messages: input_messages,
      tools: tools,
      tools_map: tools_map,
      caller_source: caller_source,
      max_iterations: max_iterations,
      tool_timeout: tool_timeout,
      intervention: intervention,
      memory: memory_opts
    }

    Logger.debug("ToolCallerLoop: starting THINK phase (initial)")

    case think(context, input_messages) do
      {:ok, response} ->
        loop(context, [response], 0)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- The Sense-Think-Act loop --

  defp loop(context, generated, iteration) do
    last = List.last(generated)

    cond do
      # ACT: LLM returned text — the loop is complete
      not has_tool_calls?(last) ->
        Logger.debug("ToolCallerLoop: ACT phase — final text response (iteration #{iteration})")
        maybe_store_assistant_response(last, context.memory)
        {:ok, generated}

      # STOP: Hit max iterations — prevent runaway loops
      iteration >= context.max_iterations ->
        Logger.warning("ToolCallerLoop: hit max_iterations (#{context.max_iterations}), stopping")
        {:ok, generated}

      # SENSE: LLM requested tool calls — gather information
      true ->
        Logger.debug(
          "ToolCallerLoop: SENSE phase — " <>
            "#{length(last.tool_calls)} tool calls (iteration #{iteration})"
        )

        {:ok, result_message, observations} =
          Sensing.sense(context.tool_agent, last.tool_calls,
            timeout: context.tool_timeout,
            intervention: context.intervention,
            tools_map: context.tools_map,
            intervention_context: %{iteration: iteration, generated_messages: generated}
          )

        maybe_record_observations(observations, context.memory, iteration)

        all_messages = context.input_messages ++ generated ++ [result_message]

        Logger.debug(
          "ToolCallerLoop: THINK phase — re-querying LLM with #{length(all_messages)} messages"
        )

        case think(context, all_messages) do
          {:ok, response} ->
            new_generated = generated ++ [result_message, response]
            loop(context, new_generated, iteration + 1)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # -- Model dispatch (supports model_fn override) --

  defp think(%{model_fn: fun, tools: tools}, messages) when is_function(fun, 2) do
    fun.(messages, tools)
  end

  defp think(%{model_client: client, tools: tools}, messages) do
    ModelClient.create(client, messages, tools: tools)
  end

  # -- Memory integration helpers --

  defp maybe_inject_memory_context(messages, nil), do: messages

  defp maybe_inject_memory_context(messages, %{
         user_id: user_id,
         project_id: project_id,
         agent_id: agent_id,
         session_id: session_id
       }) do
    Memory.inject_memory_context(messages, user_id, project_id, agent_id, session_id)
  end

  defp maybe_store_user_messages(_messages, nil), do: :ok

  defp maybe_store_user_messages(messages, %{
         user_id: user_id,
         project_id: project_id,
         agent_id: agent_id,
         session_id: session_id
       }) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.each(fn msg ->
      Memory.add_message(user_id, project_id, agent_id, session_id, "user", msg.content)
    end)
  catch
    :exit, reason ->
      Logger.debug("ToolCallerLoop: failed to store user messages: #{inspect(reason)}")
      :ok
  end

  defp maybe_store_assistant_response(_message, nil), do: :ok

  defp maybe_store_assistant_response(%Message{content: content}, %{
         user_id: user_id,
         project_id: project_id,
         agent_id: agent_id,
         session_id: session_id
       })
       when is_binary(content) and content != "" do
    Memory.add_message(user_id, project_id, agent_id, session_id, "assistant", content)
  catch
    :exit, reason ->
      Logger.debug("ToolCallerLoop: failed to store assistant response: #{inspect(reason)}")
      :ok
  end

  defp maybe_store_assistant_response(_, _), do: :ok

  defp maybe_record_observations(_observations, nil, _iteration), do: :ok

  defp maybe_record_observations(
         observations,
         %{
           user_id: user_id,
           project_id: project_id,
           agent_id: agent_id,
           session_id: session_id
         },
         iteration
       ) do
    Observer.record_observations(
      user_id,
      project_id,
      agent_id,
      session_id,
      observations,
      iteration
    )
  catch
    :exit, reason ->
      Logger.debug("ToolCallerLoop: failed to record observations: #{inspect(reason)}")
      :ok
  end

  defp has_tool_calls?(%Message{tool_calls: calls}) when is_list(calls) and calls != [], do: true
  defp has_tool_calls?(_), do: false
end
