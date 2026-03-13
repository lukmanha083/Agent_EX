# Features

## 1. Explicit Sensing Phase

In AutoGen, the sensing logic is inlined within the `tool_agent_caller_loop`'s
while-loop. In AgentEx, sensing is extracted into a dedicated `AgentEx.Sensing`
module with three clear, composable steps:

```elixir
# The full sensing phase in one call
{:ok, result_message, observations} = Sensing.sense(tool_agent, tool_calls)

# Or step by step
raw_results  = Sensing.dispatch(tool_agent, tool_calls)     # 1. Dispatch
observations = Sensing.process(raw_results, tool_calls)      # 2. Process
message      = Sensing.feed_back(observations)               # 3. Feed back
```

### Sense-Think-Act Cycle in the Loop

```
THINK → LLM decides what it needs         (ModelClient.create)
SENSE → Tools gather information           (Sensing.sense)
  ├─ dispatch: parallel tool execution     (Task.async_stream)
  ├─ process:  classify results            (pattern matching)
  └─ feed_back: package for LLM           (Message.tool_results)
THINK → LLM reasons about observations    (ModelClient.create)
...repeat until text response...
ACT   → Final answer                       (loop exits)
```

**vs. AutoGen:** Sensing is implicit — dispatch, error handling, and result
packaging are mixed together in a single `while` block. In AgentEx, each
step is a named function you can call, test, and extend independently.

```python
# AutoGen — sensing is inlined in the loop (3 concerns mixed together)
results = await asyncio.gather(*[caller.send_message(...)])  # dispatch
for result in results:                                        # process
    if isinstance(result, FunctionExecutionResult): ...
    elif isinstance(result, ToolException): ...
    elif isinstance(result, BaseException): raise result
generated_messages.append(FunctionExecutionResultMessage(...))  # feed back
```

```elixir
# AgentEx — sensing is one explicit call
{:ok, result_message, observations} = Sensing.sense(tool_agent, tool_calls)
```

### Observation Model

Every tool result — success or failure — becomes an **observation**:

| Scenario | AutoGen | AgentEx |
|---|---|---|
| Tool succeeds | `FunctionExecutionResult` | `%FunctionResult{is_error: false}` |
| Tool raises exception | `ToolException` → error result | `%FunctionResult{is_error: true}` |
| Unexpected crash | `BaseException` → **re-raised (crashes loop)** | `%FunctionResult{is_error: true}` (loop continues) |
| Timeout | No built-in per-tool timeout | `{:exit, :timeout}` → error observation |

Key insight: **sensor failures are information, not crashes**. The LLM sees
error observations and can adapt (retry, try different tool, respond without it).

## 2. Tool Permissions — Read vs Write (`:kind`)

Every tool has a `:kind` field — `:read` (default) or `:write`. This is an
AgentEx addition with no AutoGen equivalent. Inspired by Linux file permissions:

```elixir
# Sensing tool (r--) — gathers information, no side effects
Tool.new(name: "search_web", kind: :read, ...)

# Acting tool (rw-) — changes the world, has side effects
Tool.new(name: "send_email", kind: :write, ...)
Tool.new(name: "delete_file", kind: :write, ...)
```

Helper functions for checking:

```elixir
Tool.read?(tool)   # true if kind == :read
Tool.write?(tool)  # true if kind == :write
```

This classification feeds into the intervention pipeline — handlers can
auto-approve reads but gate writes. The LLM and the OpenAI API never see
the `:kind` field; it's framework-level metadata for access control.

**vs. AutoGen:** No distinction. The framework is "oblivious to the nature
of the tool call." Every tool is treated identically. AgentEx adds this
layer because acting (writing) has fundamentally different risk than
sensing (reading).

## 3. Intervention Pipeline

Tool calls pass through an intervention pipeline **before** execution.
Handlers inspect each call and decide: approve, reject, drop, or modify.

```
LLM returns [FunctionCall, FunctionCall, ...]
     │
     ▼
┌──────────────────────────────────────┐
│  Intervention Pipeline               │
│  handler1 → handler2 → handler3     │
└──────────┬───────────────────────────┘
           │
           ├── :approve     → ToolAgent executes
           ├── :reject      → "permission denied" error → LLM sees it
           ├── :drop        → silently skipped (LLM never knows)
           └── {:modify, …} → altered call sent to ToolAgent
```

### Handlers: modules or functions

```elixir
# Module-based handler (implements AgentEx.Intervention behaviour)
defmodule MyHandler do
  @behaviour AgentEx.Intervention

  @impl true
  def on_call(call, tool, context) do
    if Tool.write?(tool), do: :reject, else: :approve
  end
end

# Function-based handler (closure captures config naturally)
allowed = MapSet.new(["send_email"])
handler = fn call, tool, _ctx ->
  if Tool.write?(tool) and not MapSet.member?(allowed, call.name),
    do: :reject, else: :approve
end
```

### Built-in handlers

| Handler | Mode | Analogy |
|---|---|---|
| `PermissionHandler` | Block ALL writes | `chmod 444` (read-only) |
| `WriteGateHandler.new(allowed_writes: [...])` | Allow specific writes | `chmod +w file` |
| `LogHandler` | Audit log, always approves | `auditd` |

### Pipeline semantics

Handlers run in order. **First deny wins** (short-circuit):

```elixir
# LogHandler logs, then WriteGateHandler checks permissions
AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
  intervention: [LogHandler, WriteGateHandler.new(allowed_writes: ["send_email"])]
)
```

### Usage in the loop

```elixir
# No intervention — all tools execute (default)
AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools)

# Block all writes
AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
  intervention: [AgentEx.Intervention.PermissionHandler]
)

# Allow only specific writes
gate = AgentEx.Intervention.WriteGateHandler.new(allowed_writes: ["send_email"])
AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
  intervention: [gate]
)

# Custom: require iteration > 0 before allowing writes (think first)
handler = fn _call, tool, %{iteration: i} ->
  if Tool.write?(tool) and i == 0, do: :reject, else: :approve
end
AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
  intervention: [handler]
)
```

**vs. AutoGen:** `DefaultInterventionHandler` intercepts messages at the
runtime level via `on_send`. It applies to ALL messages between ALL agents.
In AgentEx, intervention is scoped to the sensing phase — more precise,
easier to reason about, and doesn't require a global runtime interceptor.

## 4. True Parallel Tool Execution

When the LLM requests multiple tool calls simultaneously, AgentEx executes
them in genuinely parallel BEAM processes via `Task.async_stream`.

```elixir
# Each tool call runs in its own isolated process
tool_calls
|> Task.async_stream(
     fn call -> ToolAgent.execute(tool_agent, call) end,
     timeout: 30_000,
     on_timeout: :kill_task
   )
|> Enum.map(&handle_task_result/1)
```

**vs. AutoGen (Python):**
```python
# Cooperative concurrency — one thread, tasks yield at await points
results = await asyncio.gather(*[
    caller.send_message(call, recipient=tool_agent_id)
    for call in response.content
])
```

| | AgentEx | AutoGen |
|---|---|---|
| Parallelism | Real (multi-core) | Cooperative (single thread) |
| Scheduling | Preemptive | Cooperative (yield at await) |
| CPU-bound tools | Don't block others | Block entire event loop |
| Memory per task | ~2KB (BEAM process) | Coroutine frame |

## 5. Fault-Isolated Tool Execution

Each tool call runs in its own BEAM process. If a tool crashes, only that
process dies — other tool calls continue unaffected.

```elixir
defp handle_task_result({:ok, %FunctionResult{} = result}), do: result

defp handle_task_result({:exit, reason}) do
  %FunctionResult{
    call_id: "unknown",
    name: "unknown",
    content: "Task crashed: #{inspect(reason)}",
    is_error: true
  }
end
```

A crashed tool produces an error result that gets fed back to the LLM,
which can decide how to proceed (retry, use a different tool, or respond
without it). The loop itself never crashes from a tool failure.

**vs. AutoGen:** Uses `return_exceptions=True` in `asyncio.gather` and
manually checks for `ToolException` / `BaseException`. Unexpected exceptions
are re-raised, potentially crashing the loop.

## 6. Per-Tool Timeout Protection

Each tool call has a configurable timeout (default 30 seconds). Timed-out
tasks are killed automatically.

```elixir
Task.async_stream(&execute/1, timeout: 30_000, on_timeout: :kill_task)
```

If a tool hangs (e.g., waiting on a slow API), it's killed after the timeout
and an error result is returned to the LLM. Other tools are unaffected.

**vs. AutoGen:** `CancellationToken` must be manually threaded through
every async call. No per-tool timeout — cancellation is all-or-nothing.

## 7. Iteration Limit (Runaway Loop Prevention)

The loop has a `max_iterations` option (default: 10) to prevent infinite
tool-calling cycles.

```elixir
AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
  max_iterations: 5
)
```

If the LLM keeps requesting tools beyond the limit, the loop returns
whatever messages have been generated so far.

**vs. AutoGen:** `AssistantAgent` has `max_tool_iterations`. The lower-level
`tool_agent_caller_loop` does NOT have this — it loops indefinitely until
the LLM stops calling tools.

## 8. Multi-Layer Error Handling

The ToolAgent handles errors at multiple levels, ensuring the loop never
crashes from bad input:

```
Level 1: Tool not found
  → FunctionResult{content: "Error: unknown tool 'foo'", is_error: true}

Level 2: Invalid JSON arguments
  → FunctionResult{content: "Error: invalid JSON arguments", is_error: true}

Level 3: Tool function raises an exception
  → FunctionResult{content: "Error: <exception message>", is_error: true}

Level 4: Task process crashes (OOM, timeout, etc.)
  → FunctionResult{content: "Task crashed: <reason>", is_error: true}
```

All errors produce valid `FunctionResult` structs with `is_error: true`,
which get sent back to the LLM as context. The LLM can then decide
what to do — retry, try a different approach, or respond with what it has.

## 9. Stateful Tool Registry (GenServer)

The ToolAgent is a GenServer process that holds tools in its state. This means:

- **Tools persist** across multiple loop iterations
- **Tools can be shared** — multiple callers can use the same ToolAgent
- **Tools are isolated** — the ToolAgent runs in its own process
- **Named registration** — tools can be looked up by name via `AgentEx.Registry`

```elixir
# Start a named ToolAgent
{:ok, _pid} = AgentEx.ToolAgent.start_link(
  tools: [weather_tool, calc_tool],
  name: {:via, Registry, {AgentEx.Registry, "tools:default"}}
)

# Look it up from anywhere
agent = {:via, Registry, {AgentEx.Registry, "tools:default"}}
AgentEx.ToolAgent.execute(agent, call)
```

## 10. OpenAI-Compatible API Client

The ModelClient speaks the OpenAI chat completions protocol, with support for:

- **Tool definitions** — converts `AgentEx.Tool` structs to OpenAI function schemas
- **Tool call responses** — properly encodes assistant messages with `tool_calls`
- **Tool results** — encodes `FunctionResult` as tool-role messages
- **Configurable base URL** — works with any OpenAI-compatible API (OpenRouter,
  Ollama, Azure OpenAI, local models, etc.)
- **Environment-based API key** — reads from `OPENAI_API_KEY` if not provided

```elixir
# OpenAI
client = AgentEx.ModelClient.new(model: "gpt-4o")

# Local Ollama
client = AgentEx.ModelClient.new(
  model: "llama3",
  base_url: "http://localhost:11434/v1"
)

# OpenRouter
client = AgentEx.ModelClient.new(
  model: "anthropic/claude-sonnet-4-20250514",
  base_url: "https://openrouter.ai/api/v1",
  api_key: System.get_env("OPENROUTER_API_KEY")
)
```

## 11. Clean Type Contracts via Structs + Pattern Matching

Instead of Python's `isinstance()` checks and union types, AgentEx uses
Elixir's struct pattern matching:

```elixir
# Python (AutoGen)
if isinstance(response.content, list) and all(isinstance(item, FunctionCall) for item in response.content):
    # handle tool calls
elif isinstance(response.content, str):
    # handle text

# Elixir (AgentEx)
case latest.content do
  content when is_binary(content) ->
    # handle text — done
  function_calls when is_list(function_calls) ->
    # handle tool calls — continue loop
end
```

All message types enforce required keys at construction time via `@enforce_keys`,
catching missing fields at compile time rather than runtime.

## 12. Recursive Loop (No Mutable State)

The tool-calling loop is implemented as a tail-recursive function with
immutable data:

```elixir
defp loop(tool_agent, client, input, tools, generated, source, max_iter, current_iter) do
  # ...
  new_generated = generated ++ [result_message, response]
  loop(tool_agent, client, input, tools, new_generated, source, max_iter, current_iter + 1)
end
```

- No mutable variables — `generated` accumulates via list concatenation
- No side effects beyond HTTP calls and tool execution
- Easy to reason about — each recursive call has a complete snapshot of state
- Tail-call optimized by the BEAM VM

**vs. AutoGen:** Uses a `while` loop with mutable `generated_messages` list
and in-place `.append()` calls.

## 13. OTP Supervision and Registry

The application starts a supervisor tree that provides:

- **Automatic restart** — if a ToolAgent crashes, the supervisor restarts it
- **Graceful shutdown** — processes are terminated in order on application stop
- **Named registration** — agents can be found by name via `AgentEx.Registry`
- **Health monitoring** — supervisors track child process health

```elixir
# application.ex
children = [
  {Registry, keys: :unique, name: AgentEx.Registry}
]
opts = [strategy: :one_for_one, name: AgentEx.Supervisor]
Supervisor.start_link(children, opts)
```

This is infrastructure that AutoGen builds manually through `AgentRuntime`,
`AgentId`, and explicit registration — in Elixir, it's a few lines of OTP
configuration.

## 14. HandoffMessage and Transfer Tools

Agents can hand off conversation to other agents using auto-generated transfer
tools. This maps to AutoGen's `HandoffMessage` and `transfer_to_*()` pattern.

```elixir
# Generate transfer tools from handoff target names
tools = AgentEx.Handoff.transfer_tools(["analyst", "writer"])
# => [%Tool{name: "transfer_to_analyst", kind: :write, ...},
#     %Tool{name: "transfer_to_writer", kind: :write, ...}]

# Detect handoffs in LLM tool calls
AgentEx.Handoff.detect(tool_calls)
# => {:handoff, "analyst", %FunctionCall{...}}
# => :none
```

Transfer tools are `:write` kind, which means:
- They pass through the intervention pipeline like any other tool
- `PermissionHandler` blocks all handoffs (read-only mode)
- `WriteGateHandler` can selectively allow specific transfers:

```elixir
# Only allow transfers to analyst, block transfers to admin
gate = WriteGateHandler.new(allowed_writes: ["transfer_to_analyst"])
```

The `HandoffMessage` struct carries handoff metadata:

```elixir
%HandoffMessage{
  target: "analyst",          # Who to hand off to
  source: "planner",          # Who initiated
  content: "Needs analysis",  # Reason
  context: []                 # Optional conversation context
}
```

**vs. AutoGen:** `HandoffMessage` extends `BaseTextChatMessage` with `target`
and `context` fields. Transfer functions are generated by the `AssistantAgent`
from its `handoffs` list. In AgentEx, `Handoff.transfer_tools/1` generates
them explicitly — the same pattern, but as a standalone function rather than
baked into the agent class.

## 15. Swarm — Multi-Agent Orchestration

The Swarm module orchestrates multiple agents that collaborate through handoffs.
Each agent has its own system message, tools, and handoff targets. Agents don't
communicate directly — they hand off conversation through the Swarm orchestrator.

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

### Defining agents

```elixir
planner = Swarm.Agent.new(
  name: "planner",
  system_message: "You route tasks to the right specialist.",
  handoffs: ["analyst", "writer"]  # Can transfer to these agents
)

analyst = Swarm.Agent.new(
  name: "analyst",
  system_message: "You analyze financial data.",
  tools: [stock_tool, ratio_tool],  # Agent's own tools
  handoffs: ["planner", "user"]     # Can hand back or to user
)

writer = Swarm.Agent.new(
  name: "writer",
  system_message: "You write reports based on analysis.",
  handoffs: ["planner"]
)
```

### Running the swarm

```elixir
{:ok, messages, handoff} = Swarm.run(
  [planner, analyst, writer],
  model_client,
  [Message.user("Write a report on AAPL stock")],
  start: "planner",                    # Which agent starts
  termination: {:handoff, "user"},     # Stop when handoff targets "user"
  max_iterations: 20,                  # Safety limit across all agents
  intervention: [LogHandler, gate]     # Applied to ALL tool calls
)
```

### How it works internally

1. **Creates a ToolAgent** (GenServer) for each Swarm.Agent — holds the agent's
   tools + auto-generated transfer tools
2. **Prepends system message** — each THINK call uses the current agent's
   system_message as the first message
3. **Executes ALL tool calls** — including transfer tools, through the Sensing
   pipeline (intervention applies)
4. **Detects handoffs** — checks if any tool call name starts with `"transfer_to_"`
5. **Switches agents** — on handoff, the next THINK call uses the target agent's
   system message and tools
6. **Preserves history** — the full conversation travels with the handoff, so the
   new agent sees everything that happened before

### Termination conditions

| Condition | Swarm stops when... |
|---|---|
| `:text_response` (default) | Any agent returns text instead of tool calls |
| `{:handoff, "user"}` | An agent calls `transfer_to_user()` |
| `{:handoff, "admin"}` | An agent calls `transfer_to_admin()` |
| `max_iterations` reached | Safety limit prevents infinite agent loops |

**vs. AutoGen:** `Swarm` creates a team of `AssistantAgent` participants. Each
agent's `handoffs` list auto-generates transfer functions. The `SwarmTeam`
runtime routes `HandoffMessage` between agents. `HandoffTermination` stops the
loop when a handoff targets a specific name. In AgentEx, the same pattern uses
existing building blocks: Sensing for execution, Intervention for gating,
ToolAgent for tool registry, and a recursive loop for orchestration.

## 16. Human-in-the-Loop via Handoff Termination

The Swarm supports human-in-the-loop workflows through `HandoffTermination`.
When an agent hands off to `"user"`, the swarm pauses and returns a
`HandoffMessage` to the caller.

```elixir
# Run the swarm — stops when any agent transfers to "user"
{:ok, messages, handoff} = Swarm.run(agents, client, input,
  start: "planner",
  termination: {:handoff, "user"}
)

# The handoff tells you who needs human input
%HandoffMessage{target: "user", source: "analyst"} = handoff

# Later: resume by sending a new user message
# The conversation history (messages) can be passed back in
```

This enables patterns like:
- **Approval gates** — agent asks for human approval before proceeding
- **Clarification** — agent needs more information from the user
- **Review** — agent presents work for human review before continuing
- **Escalation** — agent can't handle the request and passes to a human

**vs. AutoGen:** Uses `HandoffTermination(target="user")` and resumes with
`team.run(task=HandoffMessage(source="user", target="Alice", content="..."))`.
In AgentEx, the same pattern works through the return value of `Swarm.run/4` —
the caller inspects the `HandoffMessage` and decides how to continue.
