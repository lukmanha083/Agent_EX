defmodule AgentEx.Intervention do
  @moduledoc """
  Intervention handler — maps to AutoGen's `DefaultInterventionHandler`.

  Intercepts tool calls BEFORE execution, allowing you to approve, reject,
  modify, or log them. This is the gatekeeper between "LLM decides" and
  "tool executes."

  Think of it like Linux file permissions:
  - `:read` tools (sensing) → auto-approved by default (like `r--`)
  - `:write` tools (acting) → can require approval (like `-w-`)

  ```
  LLM returns FunctionCall
       │
       ▼
  ┌──────────────────────────┐
  │  Intervention Pipeline   │  ← You are here
  │  handler1 → handler2 →  │
  └──────────┬───────────────┘
             │
             ├── :approve     → ToolAgent executes
             ├── :reject      → Error returned to LLM ("permission denied")
             ├── {:modify, …} → Modified call sent to ToolAgent
             └── :drop        → Silently skipped
  ```

  ## AutoGen equivalent (Python):

      class ToolInterventionHandler(DefaultInterventionHandler):
          async def on_send(self, message, *, message_context, recipient):
              if isinstance(message, FunctionCall):
                  user_input = input(f"Approve '{message.name}'? (y/n)")
                  if user_input != "y":
                      return DropMessage
              return message

  ## Elixir — handlers can be modules or functions:

      # Module-based handler
      defmodule MyHandler do
        @behaviour AgentEx.Intervention

        @impl true
        def on_call(call, tool, _context), do: :approve
      end

      # Function-based handler (closures capture config naturally)
      allowed = MapSet.new(["send_email"])
      handler = fn call, tool, _ctx ->
        if Tool.write?(tool) and not MapSet.member?(allowed, call.name),
          do: :reject, else: :approve
      end

      AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
        intervention: [MyHandler, handler]
      )
  """

  alias AgentEx.Message.FunctionCall
  alias AgentEx.Tool

  @type decision ::
          :approve
          | :reject
          | :drop
          | {:modify, FunctionCall.t()}

  @type context :: %{
          iteration: non_neg_integer(),
          generated_messages: [AgentEx.Message.t()]
        }

  @type handler :: module() | (FunctionCall.t(), Tool.t() | nil, context() -> decision())

  @doc """
  Called before each tool call is dispatched to the ToolAgent.

  Receives:
  - `call` — the `%FunctionCall{}` the LLM wants to execute
  - `tool` — the `%Tool{}` that will be called (includes `:kind`), or `nil` if unknown
  - `context` — loop context (iteration count, message history)

  Return one of:
  - `:approve` — allow the call to proceed
  - `:reject` — block the call and return an error to the LLM
  - `:drop` — silently skip the call (no error returned)
  - `{:modify, %FunctionCall{}}` — replace the call with a modified version
  """
  @callback on_call(call :: FunctionCall.t(), tool :: Tool.t() | nil, context :: context()) ::
              decision()

  @optional_callbacks [on_call: 3]

  @doc """
  Run a list of intervention handlers on a single call.

  Handlers are either modules (implementing `on_call/3`) or functions.
  They run in order — the first non-`:approve` decision short-circuits
  the pipeline (like Linux permission checks: first deny wins).
  """
  @spec run_pipeline([handler()], FunctionCall.t(), Tool.t() | nil, context()) :: decision()
  def run_pipeline([], _call, _tool, _context), do: :approve

  def run_pipeline([handler | rest], call, tool, context) do
    decision = invoke(handler, call, tool, context)

    case decision do
      :approve -> run_pipeline(rest, call, tool, context)
      other -> other
    end
  end

  defp invoke(handler, call, tool, context) when is_function(handler, 3) do
    handler.(call, tool, context)
  end

  defp invoke(handler, call, tool, context) when is_atom(handler) do
    handler.on_call(call, tool, context)
  end
end
