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

  ## Intervention pipeline

  Tool calls pass through an intervention pipeline before execution:
  - `:read` tools → auto-approved (like `r--` in Linux)
  - `:write` tools → can be gated by handlers (like `-w-` permissions)

      AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
        intervention: [AgentEx.Intervention.PermissionHandler]
      )
  """

  alias AgentEx.Message
  alias AgentEx.ModelClient
  alias AgentEx.Sensing
  alias AgentEx.Tool

  require Logger

  @type opts :: [
          max_iterations: pos_integer(),
          caller_source: String.t(),
          tool_timeout: pos_integer(),
          intervention: [AgentEx.Intervention.handler()]
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
  """
  @spec run(GenServer.server(), ModelClient.t(), [Message.t()], [Tool.t()], opts()) ::
          {:ok, [Message.t()]} | {:error, term()}
  def run(tool_agent, model_client, input_messages, tools, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    caller_source = Keyword.get(opts, :caller_source, "assistant")
    tool_timeout = Keyword.get(opts, :tool_timeout, 30_000)
    intervention = Keyword.get(opts, :intervention, [])

    # Build tools_map for intervention to look up :kind
    tools_map = Map.new(tools, fn %Tool{name: name} = tool -> {name, tool} end)

    context = %{
      tool_agent: tool_agent,
      model_client: model_client,
      input_messages: input_messages,
      tools: tools,
      tools_map: tools_map,
      caller_source: caller_source,
      max_iterations: max_iterations,
      tool_timeout: tool_timeout,
      intervention: intervention
    }

    # THINK: Initial LLM call — the LLM sees the user's question and available tools
    Logger.debug("ToolCallerLoop: starting THINK phase (initial)")

    case ModelClient.create(model_client, input_messages, tools: tools) do
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

        # === SENSING PHASE (with intervention) ===
        {:ok, result_message, _observations} =
          Sensing.sense(context.tool_agent, last.tool_calls,
            timeout: context.tool_timeout,
            intervention: context.intervention,
            tools_map: context.tools_map,
            intervention_context: %{iteration: iteration, generated_messages: generated}
          )

        # === THINK PHASE ===
        all_messages = context.input_messages ++ generated ++ [result_message]

        Logger.debug("ToolCallerLoop: THINK phase — re-querying LLM with #{length(all_messages)} messages")

        case ModelClient.create(context.model_client, all_messages, tools: context.tools) do
          {:ok, response} ->
            new_generated = generated ++ [result_message, response]
            loop(context, new_generated, iteration + 1)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp has_tool_calls?(%Message{tool_calls: calls}) when is_list(calls) and calls != [], do: true
  defp has_tool_calls?(_), do: false
end
