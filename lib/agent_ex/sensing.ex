defmodule AgentEx.Sensing do
  @moduledoc """
  The Sensing Phase — maps to AutoGen's sensing within `tool_agent_caller_loop`.

  In the Sense-Think-Act cognitive cycle, sensing is where the agent reaches
  out to the environment to gather information through tools.

  Now includes an **intervention pipeline** that intercepts tool calls
  before execution — like Linux file permissions on each tool call:

  ```
  LLM returns [FunctionCall, FunctionCall, ...]
       │
       ▼
  ┌──────────────────────────┐
  │  Intervention Pipeline   │  ← approve / reject / modify / drop
  └──────────┬───────────────┘
             │
             ▼
  ┌──────────────────────────┐
  │  Parallel Dispatch       │  ← Task.async_stream → ToolAgent
  └──────────┬───────────────┘
             │
             ▼
  ┌──────────────────────────┐
  │  Process + Feed back     │  ← classify results → Message
  └──────────────────────────┘
  ```

  ## Options
  - `:timeout` — per-tool execution timeout in ms (default: 30_000)
  - `:on_timeout` — `:kill_task` (default) or `:exit`
  - `:intervention` — list of intervention handlers (modules or functions)
  - `:tools_map` — `%{name => Tool.t()}` for intervention to check `:kind`
  - `:intervention_context` — context map passed to handlers
  - `:batch` — batch dispatch config: `%{tool_name: String.t(), items_key: String.t(), max_demand: pos_integer()}`
    When a tool call matches `tool_name` and its arguments contain a list under
    `items_key`, the call is split into individual calls processed in parallel
    via `Flow`. Results are merged back into a single `FunctionResult`.
  """

  alias AgentEx.Intervention
  alias AgentEx.Message
  alias AgentEx.Message.{FunctionCall, FunctionResult}
  alias AgentEx.ToolAgent

  require Logger

  @type observation :: FunctionResult.t()
  @type sense_result :: {:ok, Message.t(), [observation()]} | {:error, term()}

  @type batch_config :: %{
          tool_name: String.t(),
          items_key: String.t(),
          max_demand: pos_integer()
        }

  @type opts :: [
          timeout: pos_integer(),
          on_timeout: :kill_task | :exit,
          intervention: [Intervention.handler()],
          tools_map: %{String.t() => AgentEx.Tool.t()},
          intervention_context: Intervention.context(),
          batch: batch_config()
        ]

  @doc """
  Execute the full sensing phase: intervene → dispatch → process → feed back.

  Built-in provider tools (kind: :builtin) in the tools_map are automatically
  skipped during dispatch — they are executed server-side by the API provider.
  """
  @spec sense(GenServer.server(), [FunctionCall.t()], opts()) :: sense_result()
  def sense(tool_agent, tool_calls, opts \\ []) when is_list(tool_calls) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    on_timeout = Keyword.get(opts, :on_timeout, :kill_task)
    handlers = Keyword.get(opts, :intervention, [])
    tools_map = Keyword.get(opts, :tools_map, %{})

    int_context =
      Keyword.get(opts, :intervention_context, %{iteration: 0, generated_messages: []})

    {approved_calls, intervention_results} =
      intervene(tool_calls, handlers, tools_map, int_context)

    batch_config = Keyword.get(opts, :batch)

    {local_calls, builtin_calls} = split_builtin_calls(approved_calls, tools_map)

    raw_results =
      dispatch(tool_agent, local_calls,
        timeout: timeout,
        on_timeout: on_timeout,
        batch: batch_config
      )

    local_observations = process(raw_results, local_calls)
    builtin_observations = Enum.map(builtin_calls, &builtin_observation/1)

    results_map =
      (Enum.zip(local_calls, local_observations) ++ Enum.zip(builtin_calls, builtin_observations))
      |> Map.new(fn {%FunctionCall{id: id}, obs} -> {id, obs} end)

    observations = merge_results(tool_calls, results_map, intervention_results)
    result_message = feed_back(observations)

    Logger.debug(
      "Sensing complete: #{length(tool_calls)} calls → " <>
        "#{count_successful(observations)} ok, #{count_errors(observations)} errors, " <>
        "#{map_size(intervention_results)} intercepted"
    )

    {:ok, result_message, observations}
  end

  @doc """
  Step 0: Intervention — run each call through the handler pipeline.

  Returns `{approved_calls, intervention_results}` where:
  - `approved_calls` — calls that passed the pipeline
  - `intervention_results` — map of `call_id => FunctionResult` for rejected/dropped calls
  """
  @spec intervene([FunctionCall.t()], [Intervention.handler()], map(), Intervention.context()) ::
          {[FunctionCall.t()], %{String.t() => FunctionResult.t() | :drop}}
  def intervene(tool_calls, [], _tools_map, _context) do
    # No handlers — approve everything (fast path)
    {tool_calls, %{}}
  end

  def intervene(tool_calls, handlers, tools_map, context) do
    {approved, rejected} =
      Enum.reduce(tool_calls, {[], %{}}, fn %FunctionCall{id: call_id, name: name} = call,
                                            {acc_approved, acc_rejected} ->
        tool = Map.get(tools_map, name)
        decision = Intervention.run_pipeline(handlers, call, tool, context)

        case decision do
          :approve ->
            {[call | acc_approved], acc_rejected}

          :reject ->
            result = %FunctionResult{
              call_id: call_id,
              name: name,
              content:
                "Error: permission denied — tool '#{name}' was rejected by intervention handler",
              is_error: true
            }

            Logger.debug("Sensing: intervention rejected #{name}(#{call_id})")
            {acc_approved, Map.put(acc_rejected, call_id, result)}

          :drop ->
            Logger.debug("Sensing: intervention dropped #{name}(#{call_id})")
            {acc_approved, Map.put(acc_rejected, call_id, :drop)}

          {:modify, %FunctionCall{} = modified_call} ->
            Logger.debug("Sensing: intervention modified #{name}(#{call_id})")
            {[modified_call | acc_approved], acc_rejected}
        end
      end)

    {Enum.reverse(approved), rejected}
  end

  @doc """
  Step 1: Dispatch — send each FunctionCall to the ToolAgent in parallel.

  Each call runs in its own isolated BEAM process via `Task.async_stream`.
  """
  @spec dispatch(GenServer.server(), [FunctionCall.t()], keyword()) :: [
          {:ok, term()} | {:exit, term()}
        ]
  def dispatch(tool_agent, tool_calls, opts \\ [])
  def dispatch(_tool_agent, [], _opts), do: []

  def dispatch(tool_agent, tool_calls, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    on_timeout = Keyword.get(opts, :on_timeout, :kill_task)
    batch_config = Keyword.get(opts, :batch)

    tool_calls
    |> Task.async_stream(
      fn %FunctionCall{} = call ->
        Logger.debug("Sensing: dispatching #{call.name}(#{call.id})")

        if batch_config && call.name == batch_config.tool_name do
          batch_dispatch(tool_agent, call, batch_config, timeout)
        else
          ToolAgent.execute(tool_agent, call)
        end
      end,
      timeout: timeout,
      on_timeout: on_timeout,
      ordered: true
    )
    |> Enum.to_list()
  end

  @doc """
  Step 2: Process — classify raw task results into observations.
  """
  @spec process([{:ok, term()} | {:exit, term()}], [FunctionCall.t()]) :: [observation()]
  def process(raw_results, tool_calls) do
    raw_results
    |> Enum.zip(tool_calls)
    |> Enum.map(&classify_result/1)
  end

  @doc """
  Step 3: Feed back — package observations as a Message for the conversation.
  """
  @spec feed_back([observation()]) :: Message.t()
  def feed_back(observations) do
    Message.tool_results(observations)
  end

  # -- Split approved calls into local (dispatchable) and builtin (skip) --

  defp split_builtin_calls(calls, tools_map) do
    Enum.split_with(calls, fn %FunctionCall{name: name} ->
      case Map.get(tools_map, name) do
        %AgentEx.Tool{kind: :builtin} -> false
        _ -> true
      end
    end)
  end

  defp builtin_observation(%FunctionCall{id: call_id, name: name}) do
    %FunctionResult{
      call_id: call_id,
      name: name,
      content: "Built-in tool '#{name}' — results provided by the API provider"
    }
  end

  # -- Merge all results in original call order --

  defp merge_results(original_calls, results_map, intervention_results) do
    original_calls
    |> Enum.map(fn %FunctionCall{id: call_id} ->
      resolve_call(call_id, results_map, intervention_results)
    end)
    |> Enum.filter(&(&1 != :skip))
    |> Enum.map(fn {:keep, obs} -> obs end)
  end

  defp resolve_call(call_id, results_map, intervention_results) do
    case Map.fetch(results_map, call_id) do
      {:ok, obs} ->
        {:keep, obs}

      :error ->
        case Map.get(intervention_results, call_id) do
          :drop -> :skip
          %FunctionResult{} = result -> {:keep, result}
          nil -> :skip
        end
    end
  end

  # -- Result classification --

  defp classify_result({{:ok, %FunctionResult{} = result}, _call}) do
    result
  end

  defp classify_result({{:exit, reason}, %FunctionCall{id: call_id, name: name}}) do
    Logger.warning("Sensing: tool #{name}(#{call_id}) crashed: #{inspect(reason)}")

    %FunctionResult{
      call_id: call_id,
      name: name,
      content: "Error: tool execution failed — #{format_exit_reason(reason)}",
      is_error: true
    }
  end

  # -- Batch dispatch via Flow --

  defp batch_dispatch(tool_agent, %FunctionCall{} = call, batch_config, _timeout) do
    args =
      case Jason.decode(call.arguments) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{}
      end

    items_key = batch_config.items_key
    items = Map.get(args, items_key, [])
    max_demand = Map.get(batch_config, :max_demand, 10)

    if is_list(items) and length(items) > 1 do
      Logger.debug(
        "Sensing: batch dispatching #{call.name}(#{call.id}) — #{length(items)} items, max_demand=#{max_demand}"
      )

      results = run_batch_flow(tool_agent, call, args, items_key, items, max_demand)
      build_batch_result(call, results)
    else
      # Single item or not a list — dispatch normally
      ToolAgent.execute(tool_agent, call)
    end
  end

  defp run_batch_flow(tool_agent, call, args, items_key, items, max_demand) do
    items
    |> Flow.from_enumerable(max_demand: max_demand)
    |> Flow.map(&execute_batch_item(tool_agent, call, args, items_key, &1))
    |> Enum.to_list()
  end

  defp execute_batch_item(tool_agent, call, args, items_key, item) do
    individual_args = Map.put(args, items_key, item)
    individual_call = %{call | arguments: Jason.encode!(individual_args)}

    case ToolAgent.execute(tool_agent, individual_call) do
      %FunctionResult{is_error: false, content: content} -> {:ok, content}
      %FunctionResult{is_error: true, content: content} -> {:error, content}
    end
  end

  defp build_batch_result(call, results) do
    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    merged_content =
      Enum.map_join(successes, "\n---\n", fn {:ok, content} -> content end)

    error_summary =
      case errors do
        [] ->
          ""

        errs ->
          "\n\n[#{length(errs)} batch item(s) failed: " <>
            Enum.map_join(errs, "; ", fn {:error, msg} -> msg end) <> "]"
      end

    %FunctionResult{
      call_id: call.id,
      name: call.name,
      content: merged_content <> error_summary,
      is_error: successes == []
    }
  end

  # -- Helpers --

  defp format_exit_reason(:timeout), do: "timed out"
  defp format_exit_reason({:timeout, _}), do: "timed out"
  defp format_exit_reason(reason), do: inspect(reason)

  defp count_successful(observations) do
    Enum.count(observations, &(not &1.is_error))
  end

  defp count_errors(observations) do
    Enum.count(observations, & &1.is_error)
  end
end
