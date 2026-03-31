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
    # context_window can come from opts directly (orchestrator) or from memory_opts (agent)
    context_window = Keyword.get(opts, :context_window) || get_context_window(memory_opts)

    # Thread resolved context_window into memory_opts so injection sees it
    memory_opts =
      if memory_opts && context_window do
        Map.put_new(memory_opts, :context_window, context_window)
      else
        memory_opts
      end

    tools_map = Map.new(tools, fn %Tool{name: name} = tool -> {name, tool} end)

    # Inject agent-scoped context BEFORE storing, so stored messages don't
    # duplicate when inject_orchestrator_history reads them back
    input_messages = maybe_inject_memory_context(input_messages, memory_opts)

    # Store incoming task messages AFTER injecting context
    maybe_store_input_messages(input_messages, memory_opts)

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
      memory: memory_opts,
      context_window: context_window
    }

    reasoning_first = Keyword.get(opts, :reasoning_first, false)

    Logger.debug("ToolCallerLoop: starting THINK phase (initial)")

    # When reasoning_first is enabled, the first LLM call has no tools.
    # This forces the model to produce a text reasoning/plan. Then a second
    # call WITH tools lets it decide: answer directly (text) or delegate (tool call).
    if reasoning_first do
      run_with_reasoning(context, input_messages)
    else
      case think(context, input_messages) do
        {:ok, response} -> loop(context, [response], 0)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Reasoning-first: think without tools, then decide with tools --

  defp run_with_reasoning(context, input_messages) do
    Logger.debug("ToolCallerLoop: REASON phase — thinking without tools")

    with {:ok, reasoning} <- think_without_tools(context, input_messages) do
      # Feed the reasoning back as conversation context and call with tools.
      # The model can now either: (a) refine its text answer, or (b) call tools.
      messages_with_reasoning = input_messages ++ [reasoning]

      Logger.debug("ToolCallerLoop: DECIDE phase — re-querying with tools available")

      case think(context, messages_with_reasoning) do
        {:ok, decision} -> loop(context, [reasoning, decision], 0)
        {:error, reason} -> {:error, reason}
      end
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

        new_generated = generated ++ [result_message]

        # Compress if conversation exceeds context window threshold
        {compressed_input, compressed_generated} =
          maybe_compress(context.input_messages, new_generated, context.context_window)

        all_messages = compressed_input ++ compressed_generated

        Logger.debug(
          "ToolCallerLoop: THINK phase — re-querying LLM with #{length(all_messages)} messages"
        )

        case think(context, all_messages) do
          {:ok, response} ->
            loop(
              %{context | input_messages: compressed_input},
              compressed_generated ++ [response],
              iteration + 1
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # -- Mid-run compression --

  defp maybe_compress(input_messages, generated, nil), do: {input_messages, generated}

  defp maybe_compress(input_messages, generated, context_window) do
    all_messages = input_messages ++ generated
    total_tokens = Memory.TokenBudget.estimate_messages_tokens(all_messages)

    # Use orchestrator zone budgets if delegation calls are present, else generic
    if has_delegation_calls?(generated) do
      budgets = Memory.OrchestratorContext.calculate_zones(context_window)

      if total_tokens >= budgets.delegation_threshold do
        compressed = Memory.OrchestratorContext.compress_delegation_rounds(generated, budgets)
        {input_messages, compressed}
      else
        {input_messages, generated}
      end
    else
      budgets = Memory.TokenBudget.calculate(context_window)

      if Memory.TokenBudget.needs_compression?(total_tokens, budgets) do
        compress_generated(input_messages, generated)
      else
        {input_messages, generated}
      end
    end
  end

  defp has_delegation_calls?(messages) do
    Enum.any?(messages, fn
      %{tool_calls: calls} when is_list(calls) and calls != [] ->
        Enum.any?(calls, fn
          %{name: "delegate_to_" <> _} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp get_context_window(%{context_window: cw}) when is_integer(cw) and cw > 0, do: cw
  defp get_context_window(_), do: nil

  defp compress_generated(input_messages, generated) do
    # Keep the most recent 20% of generated messages (at least 4)
    keep_count = max(4, trunc(length(generated) * 0.2))
    split_at = max(0, length(generated) - keep_count)
    {old, recent} = Enum.split(generated, split_at)

    if old == [] do
      {input_messages, generated}
    else
      summary = summarize_messages(old)

      Logger.info(
        "ToolCallerLoop: compressed #{length(old)} old messages into summary " <>
          "(keeping #{length(recent)} recent)"
      )

      summary_message = %Message{
        role: :system,
        content: "[Context compressed] Previous conversation summary:\n#{summary}"
      }

      # Remove any prior compressed summaries before appending the new one
      clean_input =
        Enum.reject(input_messages, fn msg ->
          msg.role == :system and is_binary(msg.content) and
            String.starts_with?(msg.content, "[Context compressed]")
        end)

      {clean_input ++ [summary_message], recent}
    end
  end

  defp summarize_messages(messages) do
    messages
    |> Enum.map_join("\n", fn msg ->
      role = if msg.role, do: to_string(msg.role), else: "unknown"
      content = if is_binary(msg.content), do: msg.content, else: ""
      preview = String.slice(content, 0, 200)
      "#{role}: #{preview}"
    end)
    |> then(fn text ->
      if String.length(text) > 2000, do: String.slice(text, 0, 2000) <> "\n...", else: text
    end)
  end

  # -- Model dispatch (supports model_fn override) --

  defp think(%{model_fn: fun, tools: tools}, messages) when is_function(fun, 2) do
    fun.(messages, tools)
  end

  defp think(%{model_client: client, tools: tools}, messages) do
    ModelClient.create(client, messages, tools: tools)
  end

  # First call without tools — forces the LLM to reason with text
  defp think_without_tools(%{model_fn: fun}, messages) when is_function(fun, 2) do
    fun.(messages, [])
  end

  defp think_without_tools(%{model_client: client}, messages) do
    ModelClient.create(client, messages, tools: [])
  end

  # -- Memory integration helpers --

  defp maybe_inject_memory_context(messages, nil), do: messages

  defp maybe_inject_memory_context(messages, %{orchestrator: true} = memory_opts) do
    # Orchestrator: inject Tier 1 conversation history ONLY (no Tier 2/3/4/KG)
    %{user_id: uid, project_id: pid, agent_id: aid, session_id: sid} = memory_opts
    context_window = Map.get(memory_opts, :context_window)

    Memory.inject_orchestrator_history(messages, uid, pid, aid, sid,
      context_window: context_window
    )
  end

  defp maybe_inject_memory_context(messages, memory_opts) do
    # Agent: inject all tiers (Tier 1-4 + KG)
    %{user_id: user_id, project_id: project_id, agent_id: agent_id, session_id: session_id} =
      memory_opts

    context_window = Map.get(memory_opts, :context_window)

    Memory.inject_memory_context(messages, user_id, project_id, agent_id, session_id,
      context_window: context_window
    )
  end

  defp maybe_store_input_messages(_messages, nil), do: :ok

  defp maybe_store_input_messages(messages, %{orchestrator: true} = opts) do
    # Orchestrator: store actual user messages (from the human)
    %{user_id: uid, project_id: pid, agent_id: aid, session_id: sid} = opts

    messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.each(fn msg ->
      Memory.add_message(uid, pid, aid, sid, "user", msg.content)
    end)
  catch
    :exit, reason ->
      Logger.debug("ToolCallerLoop: failed to store orchestrator input: #{inspect(reason)}")
      :ok
  end

  defp maybe_store_input_messages(messages, %{
         user_id: user_id,
         project_id: project_id,
         agent_id: agent_id,
         session_id: session_id
       }) do
    # Agent: store delegation tasks from orchestrator (not human messages)
    messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.each(fn msg ->
      Memory.add_message(user_id, project_id, agent_id, session_id, "task", msg.content)
    end)
  catch
    :exit, reason ->
      Logger.debug("ToolCallerLoop: failed to store input messages: #{inspect(reason)}")
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
