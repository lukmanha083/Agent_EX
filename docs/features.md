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

## 17. 3-Tier Agent Memory System

AgentEx includes a memory system with three tiers, each using native BEAM/OTP
primitives. All operations are scoped by `agent_id` for multi-agent isolation.

### Tier 1: Working Memory (GenServer)

Short-term conversation history. Each `{agent_id, session_id}` pair spawns a
dedicated GenServer via DynamicSupervisor.

```elixir
# Per-agent, per-session — isolated by design
Memory.start_session("analyst", "session-1")
Memory.add_message("analyst", "session-1", "user", "Analyze AAPL")
Memory.get_messages("analyst", "session-1")  # only analyst's messages
Memory.stop_session("analyst", "session-1")
```

**OTP advantage**: Each session is a separate process — no shared mutable state,
automatic cleanup via DynamicSupervisor, and process isolation means one
session crash doesn't affect others.

### Tier 2: Persistent Memory (ETS + DETS)

Long-term key-value facts. ETS provides microsecond reads; DETS provides
disk persistence. Periodic sync keeps them in agreement.

```elixir
Memory.remember("analyst", "expertise", "financial analysis", "fact")
{:ok, entry} = Memory.recall("analyst", "expertise")
# entry.value => "financial analysis"

# Survives process restarts — DETS rehydrates ETS automatically
```

**OTP advantage**: ETS gives lock-free concurrent reads. DETS handles disk
persistence without external dependencies. The supervisor auto-restarts the
Store process, which rehydrates from DETS on init.

### Tier 3: Semantic Memory (HelixDB Vectors)

Vector-based semantic search. Text is embedded via OpenAI and stored in
HelixDB. Search returns semantically similar results.

```elixir
Memory.store_memory("analyst", "AAPL P/E ratio is 28.5", "analysis")
results = Memory.search_memory("analyst", "Apple valuation", 5)
```

**Agent isolation**: Vectors are tagged with `agent_id` on insert and filtered
client-side on search (over-fetch 3x, then filter by agent_id).

## 18. Knowledge Graph

Entity/relationship extraction via LLM, stored as a graph in HelixDB. Enables
richer context than vector search alone by understanding connections between
entities.

### Ingestion pipeline (per conversation turn)

```
User message → Create Episode → LLM Extraction → Entity Resolution → Store Facts
```

1. **Episode**: Stores the raw conversation turn with an embedding
2. **Extraction**: LLM extracts entities (PERSON, CONCEPT, ARTIFACT...) and relationships
3. **Resolution**: New entities matched against existing via vector similarity (>0.85 = merge)
4. **Facts**: Relationships stored as graph edges with confidence levels

### Hybrid retrieval (3 parallel strategies)

```elixir
Memory.hybrid_search("analyst", "testing framework", 5)
```

Runs in parallel via `Task.async`:
- **Vector search**: Embed query → search episodes (agent-scoped)
- **Entity traversal**: Find entities → follow graph edges (shared)
- **Fact search**: Embed query → match relationship descriptions (shared)

Results are merged, deduplicated, and ranked by recency + confidence.

**Design choice**: Episodes are per-agent (private), but entities and facts
are shared. This enables agents to build on each other's domain knowledge
while keeping conversation history private.

## 19. Memory-Integrated Agent Loops

Both the single-agent ToolCallerLoop and multi-agent Swarm support automatic
memory integration via a `:memory` option.

### ToolCallerLoop with memory

```elixir
{:ok, result} = ToolCallerLoop.run(agent, client, messages, tools,
  memory: %{agent_id: "analyst", session_id: "session-1"}
)
# Before THINK: injects memory context as system messages
# After ACT: stores user + assistant messages in working memory
```

### Swarm with memory

```elixir
{:ok, msgs, handoff} = Swarm.run(agents, client, messages,
  start: "planner",
  memory: %{session_id: "swarm-session-1"}
)
# Each agent.name becomes its agent_id
# Sessions auto-created at start, auto-cleaned at end
# Each agent's THINK call gets its own memory context injected
```

**vs. AutoGen:** AutoGen's memory is typically managed at the `AssistantAgent`
level via `ChatHistoryManager`. In AgentEx, memory is a separate system that
integrates at the loop level — the ToolCallerLoop and Swarm are memory-aware,
but the memory system is usable independently.

## 20. Per-Agent Memory Isolation

Every memory operation takes `agent_id` as its first parameter. Multiple agents
sharing a session still get completely separate memory:

```elixir
# Same session, different agents — fully isolated
Memory.start_session("analyst", "session-1")
Memory.start_session("writer", "session-1")

Memory.remember("analyst", "expertise", "data analysis", "fact")
Memory.remember("writer", "style", "concise", "preference")

Memory.recall("analyst", "expertise")  # => {:ok, %{value: "data analysis"}}
Memory.recall("writer", "expertise")   # => :not_found
Memory.recall("analyst", "style")      # => :not_found
Memory.recall("writer", "style")       # => {:ok, %{value: "concise"}}
```

This enables architectures where multiple specialized agents coexist — each
with its own personality, knowledge, and conversation history — without any
risk of memory leaking between them.

For the full memory guide, see [Memory System](memory.md).

## 21. ToolOverride — Rename/Redescribe Tools

Wrap an existing tool with overridden metadata without modifying the original.
The LLM sees the override name/description; intervention checks the original kind.

```elixir
alias AgentEx.{Tool, ToolOverride}

original = Tool.new(name: "search_db", description: "Search database", kind: :read, ...)

# Rename
renamed = ToolOverride.rename(original, "find_records")
renamed.name  #=> "find_records"
renamed.kind  #=> :read (preserved)

# Redescribe
updated = ToolOverride.redescribe(original, "Look up records in the database")

# Override multiple fields
wrapped = ToolOverride.wrap(original, name: "find", description: "Find things")
```

**vs. AutoGen:** `ToolOverride` class wraps a tool with overridden metadata.
In AgentEx, `ToolOverride.wrap/2` creates a new `%Tool{}` with a closure that
delegates to the original function. The original name is stored for traceability.

## 22. ToolBuilder — Auto-Schema from Param Specs

Auto-generate JSON Schema for tool parameters from declarative specs. Since
Elixir lacks Python's runtime type introspection, we use a DSL approach.

### Function-based builder

```elixir
tool = AgentEx.ToolBuilder.build(
  name: "get_weather",
  description: "Get weather for a city",
  kind: :read,
  params: [
    {:city, :string, "City name"},
    {:units, :string, "C or F", optional: true}
  ],
  function: fn %{"city" => city} -> {:ok, "Sunny in #{city}"} end
)

tool.parameters
#=> %{
#     "type" => "object",
#     "properties" => %{
#       "city" => %{"type" => "string", "description" => "City name"},
#       "units" => %{"type" => "string", "description" => "C or F"}
#     },
#     "required" => ["city"]
#   }
```

### Macro DSL

```elixir
defmodule MyTools do
  import AgentEx.ToolBuilder

  deftool :get_weather, "Get weather for a city", kind: :read do
    param :city, :string, "City name"
    param :units, :string, "C or F", optional: true
  end

  def get_weather(%{"city" => city} = _args), do: {:ok, "Sunny in #{city}"}
end

tool = MyTools.get_weather_tool()
```

### Type mapping

| Elixir spec | JSON Schema |
|---|---|
| `:string` | `"string"` |
| `:integer` | `"integer"` |
| `:number` | `"number"` |
| `:boolean` | `"boolean"` |
| `{:enum, ["a", "b"]}` | `"string"` + `"enum"` |
| `{:array, :string}` | `"array"` + `"items"` |
| `{:object, [{:city, :string, "City"}]}` | nested `"object"` |

**vs. AutoGen:** Uses Pydantic models to auto-generate JSON Schema from Python
type annotations at runtime. In AgentEx, `ToolBuilder` achieves the same with
explicit param specs (function-based) or a compile-time macro DSL.

## 23. StatefulTool — Persistent Tool State

Wrap a tool so its function receives persisted state and can update it across
sessions. Uses `AgentEx.Memory.PersistentMemory.Store` (Tier 2) for storage.

```elixir
alias AgentEx.{StatefulTool, Tool}

# Define a tool that tracks state
counter_tool = Tool.new(
  name: "increment",
  description: "Increment a counter",
  parameters: %{},
  function: fn %{"__state" => %{"count" => c}} ->
    {:ok, "count: #{c + 1}", %{"count" => c + 1}}
  end
)

# Wrap with persistent state
wrapped = StatefulTool.wrap(counter_tool,
  state_key: "counter",
  agent_id: "bot",
  initial_state: %{"count" => 0}
)

# State persists across calls
Tool.execute(wrapped, %{})  #=> {:ok, "count: 1"}
Tool.execute(wrapped, %{})  #=> {:ok, "count: 2"}
```

### Return value conventions

- `{:ok, result}` — no state change
- `{:ok, result, new_state}` — state updated and persisted
- `{:error, reason}` — error propagated, no state change

### State isolation

Each `{agent_id, state_key}` pair gets its own independent state. Different
agents using the same tool with the same state_key don't interfere.

**vs. AutoGen:** `BaseToolWithState` provides `save_state()`/`load_state()` methods.
In AgentEx, `StatefulTool.wrap/2` transparently handles state loading/saving
through the existing Tier 2 memory system — no manual save/load needed.

## 24. Workbench — Dynamic Tool Collection

A GenServer that manages a mutable registry of tools with version tracking.
Tools can be added, removed, and updated at runtime.

```elixir
alias AgentEx.Workbench

{:ok, wb} = Workbench.start_link()

# Add/remove/update tools dynamically
:ok = Workbench.add_tool(wb, weather_tool)
:ok = Workbench.add_tool(wb, search_tool)
:ok = Workbench.remove_tool(wb, "search")
:ok = Workbench.update_tool(wb, "get_weather", description: "Updated description")

# Execute tools
result = Workbench.call_tool(wb, "get_weather", %{"city" => "Tokyo"})

# Version tracking — only resend tools to LLM when they've changed
v1 = Workbench.version(wb)
Workbench.add_tool(wb, new_tool)
{:changed, tools, v2} = Workbench.tools_if_changed(wb, v1)

# Add tools with ToolOverride
Workbench.add_override(wb, original_tool, name: "custom_name")
```

**vs. AutoGen:** `Workbench` protocol with `list_tools`/`call_tool`. In AgentEx,
the Workbench is a GenServer with built-in version tracking — callers can detect
changes and avoid unnecessary tool list updates to the LLM.

## 25. StreamTool — Streaming Tool Results

Tools that produce incremental results via streaming. The collector aggregates
chunks; the final result is returned as a normal `FunctionResult` — transparent
to the LLM.

```elixir
alias AgentEx.{StreamTool, Tool}

# Define a streaming tool function (receives args + emit callback)
stream_fn = fn %{"query" => q}, emit ->
  for i <- 1..3 do
    Process.sleep(100)
    emit.({:chunk, "result #{i} for #{q}"})
  end
  {:ok, "3 results found for #{q}"}
end

tool = Tool.new(name: "search", description: "Search", parameters: %{},
  function: stream_fn)

# Wrap into a standard tool (transparent to LLM)
wrapped = StreamTool.wrap(tool, timeout: 30_000, max_chunks: 100)

# Or collect chunks directly
{:ok, result} = StreamTool.collect(stream_fn, %{"query" => "elixir"},
  on_chunk: fn chunk -> IO.inspect(chunk) end
)
```

### Options

| Option | Default | Description |
|---|---|---|
| `timeout` | `30_000` | Max time to wait for completion (ms) |
| `max_chunks` | `1_000` | Max chunks before abort |
| `on_chunk` | `nil` | Optional callback for each chunk |

### Chunk types

- `{:chunk, data}` — a partial result
- `{:progress, percentage}` — progress indicator

**vs. AutoGen:** `StreamTool` protocol returns an `AsyncGenerator`. In AgentEx,
streaming uses `Task.async` + message passing for the emit callback. The
`collect/3` function receives messages in a loop until completion or timeout.

## 26. MCP Client — Model Context Protocol Bridge

Connect to external MCP (Model Context Protocol) servers and use their tools
as native AgentEx tools.

```elixir
alias AgentEx.MCP.{Client, ToolAdapter}

# Connect via stdio transport (spawns subprocess)
{:ok, mcp} = Client.start_link(
  transport: {:stdio, "npx -y @anthropic-ai/mcp-server-github"}
)

# Or via HTTP transport
{:ok, mcp} = Client.start_link(
  transport: {:http, "http://localhost:3000/mcp"}
)

# Discover and convert tools
tools = ToolAdapter.list_tools(mcp)
#=> [%Tool{name: "list_repos", kind: :read, ...}, %Tool{name: "create_issue", kind: :write, ...}]

# Use with any AgentEx component
{:ok, agent} = ToolAgent.start_link(tools: tools ++ local_tools)

# Or call tools directly
{:ok, result} = Client.call_tool(mcp, "list_repos", %{"org" => "anthropics"})
```

### Protocol support

| Method | Description |
|---|---|
| `initialize` | Capability negotiation |
| `tools/list` | Discover available tools |
| `tools/call` | Invoke a tool with arguments |
| `resources/list` | List available resources |
| `resources/read` | Read a resource by URI |

### Transport adapters

| Transport | Implementation | Use case |
|---|---|---|
| Stdio | `Port.open` (Erlang port) | Local MCP servers as subprocesses |
| HTTP | `Req.post` | Remote MCP servers over HTTP |

### Tool kind inference

The `ToolAdapter` infers `:read` or `:write` kind from the tool name and
description. Tools with verbs like "create", "delete", "update", "write"
are classified as `:write`; all others default to `:read`.

**vs. AutoGen:** `mcp_server_tools` function discovers and wraps MCP tools.
In AgentEx, `MCP.Client` is a GenServer managing the connection, and
`MCP.ToolAdapter` converts MCP tools to native `%Tool{}` structs that work
with ToolAgent, Workbench, Sensing, and Intervention.

## 27. Multi-Provider ModelClient

The ModelClient supports multiple LLM providers with provider-specific encoding:

```elixir
alias AgentEx.ModelClient

# OpenAI (default)
client = ModelClient.openai("gpt-4o")

# Anthropic Claude
client = ModelClient.anthropic("claude-sonnet-4-20250514")

# Moonshot/Kimi
client = ModelClient.moonshot("moonshot-v1-8k")

# Custom OpenAI-compatible endpoint
client = ModelClient.new(
  model: "llama3",
  provider: :openai,
  base_url: "http://localhost:11434/v1"
)

# With options
{:ok, response} = ModelClient.create(client, messages,
  tools: tools,
  temperature: 0.7,
  response_format: %{"type" => "json_object"}
)
```

### Provider differences

| Feature | OpenAI | Anthropic | Moonshot |
|---|---|---|---|
| Message format | OpenAI standard | Anthropic native | OpenAI-compatible |
| System messages | In messages array | Separate `system` param | In messages array |
| Tool schema | `function` wrapper | Flat `input_schema` | Same as OpenAI |
| Temperature | Unclamped | Clamped [0, 1] | Clamped [0, 1] |
| Response format | Supported | Supported | Not supported |
| Built-in tools | N/A | `type` field | `builtin_function` |

### Built-in tools

Provider-executed server-side tools (no local function):

```elixir
# Anthropic web search
web_search = Tool.builtin("web_search", type: "web_search_20260209")

# Include alongside regular tools
ModelClient.create(client, messages, tools: [weather_tool, web_search])
```
