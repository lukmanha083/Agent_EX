# Architecture — AutoGen to OTP Mapping

## Process Architecture

AgentEx maps AutoGen's runtime concepts to an OTP supervision tree:

```
AgentEx.Supervisor (:one_for_one)
├── AgentEx.Registry                           — Named process lookup (AgentId equivalent)
│
│   Agent Framework (dynamic)
├── ToolAgent (GenServer)                      — Executes tools, holds tool registry
├── ToolAgent (GenServer)                      — Multiple agents can coexist
├── ToolAgent (GenServer)                      — Swarm creates one per Swarm.Agent
│
│   Memory System (static)
├── AgentEx.Memory.SessionRegistry             — Working memory session lookup
├── AgentEx.Memory.WorkingMemory.Supervisor    — DynamicSupervisor for sessions
│   ├── WorkingMemory.Server {analyst, sess-1} — Per-agent, per-session GenServer
│   ├── WorkingMemory.Server {writer, sess-1}  — Each agent gets its own process
│   └── ...
├── AgentEx.Memory.PersistentMemory.Store      — ETS + DETS singleton (Tier 2)
├── AgentEx.Memory.SemanticMemory.Store        — HelixDB vector client (Tier 3)
└── AgentEx.Memory.KnowledgeGraph.Store        — Graph operations (KG)
```

### Why `:one_for_one`?

Each component is independent. If a ToolAgent crashes, only that agent restarts.
If PersistentMemory.Store crashes, the supervisor restarts it and DETS
rehydrates ETS automatically. Other agents and memory tiers continue operating.

## Component Roles

### ToolAgent (GenServer)

**AutoGen equivalent:** `autogen_core.tool_agent.ToolAgent`

A stateful process that:
- Holds a map of registered tools (`%{name => Tool.t()}`)
- Holds an optional `agent_id` for per-agent scoping (used by StatefulTool, Workbench)
- Receives `FunctionCall` messages via `GenServer.call/2`
- Executes the matching tool and returns a `FunctionResult`
- Handles errors gracefully (unknown tool, bad JSON, execution failure)

```
State: %{tools: %{"get_weather" => Tool.t(), "calculator" => Tool.t()}, agent_id: "analyst"}

Incoming:  GenServer.call(pid, {:execute, %FunctionCall{name: "get_weather", ...}})
Outgoing:  %FunctionResult{content: "Sunny, 25°C", is_error: false}
```

In AutoGen, the caller sends `FunctionCall` as a message through the runtime:
```python
result = await caller.send_message(call, recipient=tool_agent_id)
```

In Elixir, this is a direct GenServer call — the BEAM's message passing IS the runtime:
```elixir
result = AgentEx.ToolAgent.execute(tool_agent_pid, call)
```

### Intervention (Behaviour + Functions)

**AutoGen equivalent:** `DefaultInterventionHandler`

A pipeline that intercepts tool calls **before** execution. Like Linux file
permissions — each tool has a `:kind` (`:read` or `:write`), and handlers
decide whether to approve, reject, modify, or drop each call.

```
LLM returns FunctionCall
     │
     ▼
┌──────────────────────────────────────┐
│  Intervention Pipeline               │
│  handler1 → handler2 → handler3     │
│                                      │
│  Decisions:                          │
│  :approve     → tool executes        │
│  :reject      → "permission denied"  │
│  :drop        → silently skipped     │
│  {:modify, …} → altered call runs    │
└──────────┬───────────────────────────┘
           │
           ▼
     ToolAgent.execute()
```

Handlers can be modules (implementing `on_call/3`) or anonymous functions
(closures that capture config). First deny wins — like permission checks.

AutoGen's `ToolInterventionHandler` intercepts messages via the runtime's
`on_send` hook. In AgentEx, the intervention pipeline is part of `Sensing`,
which is a cleaner separation — the pipeline runs before dispatch, not
as a runtime-level message interceptor.

### Sensing (Stateless Module)

**AutoGen equivalent:** The sensing logic inside `tool_agent_caller_loop`'s while-loop

In AutoGen, sensing is mixed into the loop body. In AgentEx, it's extracted into
a dedicated module with four composable steps:

1. **Intervene** — Run each `FunctionCall` through the intervention pipeline.
   Rejected calls get a "permission denied" error result. Dropped calls are skipped.
2. **Dispatch** — Send approved calls to the ToolAgent in parallel via `Task.async_stream`.
   Each call runs in its own isolated BEAM process.
3. **Process** — Classify raw results into observations. Successes become
   `%FunctionResult{is_error: false}`, crashes/timeouts become `%FunctionResult{is_error: true}`.
4. **Feed back** — Package observations as a `%Message{role: :tool}` ready to be
   appended to conversation history for the next LLM call.

```
                    ┌──────────────────────────────────────────────────┐
                    │              Sensing.sense/3                     │
                    │                                                  │
  [FunctionCall] ──▶│  intervene ──▶ dispatch ──▶ process ──▶ feed_back│──▶ %Message{role: :tool}
                    │  (permit?)     (parallel)   (classify)  (package) │
                    └──────────────────────────────────────────────────┘
```

### ToolCallerLoop (Stateless Module)

**AutoGen equivalent:** `autogen_core.tool_agent.tool_agent_caller_loop`

A pure orchestration function (no process, no state) implementing the
Sense-Think-Act cycle. It:
1. **THINK** — Calls the LLM via `ModelClient`
2. Checks if the response contains tool calls
3. **SENSE** — If yes → delegates to `Sensing.sense/3` for parallel execution
4. **THINK** — Re-queries the LLM with observations
5. Repeats until the LLM returns text (**ACT**) or `max_iterations` is hit

This is deliberately stateless — the conversation history is passed through
each recursive call, making the function referentially transparent.

### Handoff (Structs + Functions)

**AutoGen equivalent:** `HandoffMessage` + `transfer_to_*()` tool generation

Two components:

1. **`HandoffMessage`** — A struct representing a conversation transfer:
   - `target` — name of the agent to hand off to
   - `content` — human-readable reason for the handoff
   - `source` — who initiated the handoff
   - `context` — optional conversation history to pass along

2. **Transfer tool generation** — Converts a list of handoff target names into
   `Tool.t()` structs that the LLM can call. Each transfer tool:
   - Has name `"transfer_to_<target>"`
   - Is `:write` kind (handoffs are actions — gated by intervention)
   - Returns a string like `"Transferred to <target>"`

The key insight: **handoffs are just tool calls in disguise**. The LLM doesn't
need special handoff logic — it sees transfer tools alongside regular tools and
decides which to call. The framework detects the transfer and routes accordingly.

```
LLM sees: [get_weather, lookup_stock, transfer_to_analyst, transfer_to_writer]
LLM calls: transfer_to_analyst(reason: "needs financial analysis")
Framework: detects "transfer_to_" prefix → switch to analyst agent
```

### Swarm (Stateless Module + Agent Struct)

**AutoGen equivalent:** `Swarm` / `SwarmTeam`

Multi-agent orchestration via handoffs. Each `Swarm.Agent` has:
- `name` — unique identifier
- `system_message` — injected as the first message for each THINK call
- `tools` — regular tools this agent can use
- `handoffs` — list of agent names this agent can transfer to

The Swarm orchestrator:
1. Creates a ToolAgent (GenServer) for each Swarm.Agent (holds tools + transfer tools)
2. Starts with the designated starting agent
3. Runs a loop: THINK → detect handoff or tool calls → SENSE → route → repeat
4. Switches agents when a transfer tool is detected
5. Terminates when a handoff targets a specific name (like `"user"`) or the LLM returns text

```
User Question
     │
     ▼
┌──────────────────────────────────────────────────────┐
│              Swarm Loop                               │
│                                                      │
│  THINK ─▶ Planner LLM decides                       │
│     │     "Transfer to analyst"                      │
│     ▼                                                │
│  SENSE ─▶ Execute transfer tool                     │
│     │                                                │
│  ROUTE ─▶ Switch to Analyst agent                   │
│     │                                                │
│  THINK ─▶ Analyst LLM decides                       │
│     │     "Need stock data"                          │
│     ▼                                                │
│  SENSE ─▶ Execute lookup_stock tool                 │
│     │                                                │
│  THINK ─▶ Analyst responds with analysis            │
│     │                                                │
│  ──── text response ──▶ EXIT                        │
└──────────────────────────────────────────────────────┘
     │
     ▼
Answer to User
```

### ToolOverride (Stateless Module)

**AutoGen equivalent:** `ToolOverride` wrapper class

Wraps an existing `%Tool{}` with metadata overrides (name, description, parameters)
while preserving the original function and kind. The LLM sees the override;
intervention checks the original kind.

```
Original:  %Tool{name: "search_db", kind: :read, ...}
     │
     ▼
ToolOverride.rename(original, "find_records")
     │
     ▼
Wrapped:   %Tool{name: "find_records", kind: :read, function: <delegates to original>}
```

### ToolBuilder (Stateless Module + Macro)

**AutoGen equivalent:** Pydantic-based schema generation from function signatures

Auto-generates JSON Schema from declarative param specs. Two modes:

1. **Function-based builder** — `ToolBuilder.build/1` takes param specs and returns a `%Tool{}`
2. **Macro DSL** — `deftool` generates a `<name>_tool/0` function at compile time

Type mapping: `:string`, `:integer`, `:number`, `:boolean`, `{:enum, vals}`,
`{:array, type}`, `{:object, fields}`.

### StatefulTool (Stateless Module)

**AutoGen equivalent:** `BaseToolWithState` with `save_state()`/`load_state()`

Wraps a tool so its function receives persisted state and can update it.
Uses `AgentEx.Memory.PersistentMemory.Store` (Tier 2) for persistence.

```
Tool call → load state from Tier 2 → merge into args as "__state"
     → execute original function → save new state to Tier 2 → return result
```

The function returns `{:ok, result}` (no change) or `{:ok, result, new_state}` (persist).
Each `{agent_id, state_key}` pair gets its own isolated state.

### Workbench (GenServer)

**AutoGen equivalent:** `Workbench` protocol with `list_tools/call_tool`

A GenServer that manages a mutable tool registry with version tracking.
Tools can be added, removed, and updated at runtime. The version counter
lets callers detect changes and avoid resending unchanged tool lists to the LLM.

```
State: %{tools: %{name => Tool.t()}, version: non_neg_integer(), agent_id: String.t() | nil}
```

Integrates with ToolOverride via `add_override/3`.

### StreamTool (Stateless Module)

**AutoGen equivalent:** `StreamTool` protocol with `run_json_stream` returning `AsyncGenerator`

Tools that produce incremental results. The streaming function uses an `emit` callback
to send chunks; the collector aggregates them. From the LLM's perspective, streaming
tools are indistinguishable from normal tools — the result is aggregated before being
returned as a `FunctionResult`.

```
Streaming function:  fn args, emit -> emit.({:chunk, ...}); {:ok, "final"} end
     │
     ▼
StreamTool.wrap(tool)  →  standard tool that collects chunks internally
     │
     ▼
LLM sees:  {:ok, "final"}  (aggregated, transparent)
```

Implementation uses `Task.async` + message passing for the emit callback.

### MCP Client (GenServer + Transport)

**AutoGen equivalent:** `mcp_server_tools` integration

Bridges external MCP (Model Context Protocol) servers to AgentEx:

```
AgentEx.MCP.Client (GenServer)
     │
     ├── Transport.Stdio  →  Port.open() → subprocess stdin/stdout
     └── Transport.HTTP   →  Req.post() → HTTP endpoint
     │
     ▼
AgentEx.MCP.ToolAdapter  →  converts MCP tools to %AgentEx.Tool{} structs
```

JSON-RPC 2.0 protocol: `initialize` → `tools/list` → `tools/call`.
The `ToolAdapter` wraps each MCP tool as an AgentEx tool where the function
closure calls `MCP.Client.call_tool/3`.

### ModelClient (Struct)

**AutoGen equivalent:** `ChatCompletionClient`

A data struct (not a process) that holds API configuration. Supports multiple providers:

- `:openai` — OpenAI-compatible APIs (default)
- `:anthropic` — Anthropic Claude APIs (different message format)
- `:moonshot` — Moonshot/Kimi APIs (OpenAI-compatible with built-in tools)

Also supports:
- `temperature:` option (clamped to [0,1] for Moonshot/Anthropic)
- `response_format:` option (not supported on Moonshot)
- Built-in tools (`:builtin` kind) — provider-executed server-side tools

Uses `Req` for HTTP. Stateless — each `create/3` call is independent.

### Message (Structs)

**AutoGen equivalent:** `LLMMessage` union types

Elixir structs with pattern matching replace Python's class hierarchy:

| AutoGen | AgentEx |
|---|---|
| `SystemMessage(content="...")` | `Message.system("...")` |
| `UserMessage(content="...", source="user")` | `Message.user("...", "user")` |
| `AssistantMessage(content="...")` | `Message.assistant("...")` |
| `AssistantMessage(content=[FunctionCall, ...])` | `Message.assistant_tool_calls([...])` |
| `FunctionExecutionResultMessage(content=[...])` | `Message.tool_results([...])` |

### Tool (Struct)

**AutoGen equivalent:** `FunctionTool` / `ToolSchema`

Combines schema and implementation in one struct:
- `name`, `description`, `parameters` — sent to LLM as JSON schema
- `function` — the actual `fn` to execute (`(map -> {:ok, v} | {:error, r})`)
- `kind` — `:read` (default), `:write`, or `:builtin` (provider-executed)
- `type` — optional provider-specific type string (for built-in tools)

The `:kind` field is an AgentEx addition (AutoGen has no equivalent). It enables
Linux-style permission semantics: read tools gather information (sensing), write
tools change the world (acting). Built-in tools (`:builtin`) are executed
server-side by the API provider (e.g., Anthropic's web search).

## Message Flow

A complete request flows through the system like this:

```
1. User builds input messages
   [Message.system("..."), Message.user("What's the weather?")]

2. ToolCallerLoop.run/5 starts

   THINK ─▶ ModelClient.create() ──HTTP──▶ OpenAI API
   │                                            │
   │  ◀── {:ok, %Message{tool_calls: [%FunctionCall{name: "get_weather"}]}}
   │
   SENSE ─▶ Sensing.sense(tool_agent, tool_calls, intervention: [...])
   │         │
   │         ├─ intervene: run pipeline (approve/reject/drop/modify each call)
   │         │   ├─ :read tools → auto-approved
   │         │   ├─ :write tools → checked against handlers
   │         │   └─ rejected → "permission denied" error result
   │         │
   │         ├─ dispatch: Task.async_stream (parallel, approved calls only)
   │         │   ├─ Process 1: ToolAgent.execute(pid, call_1) → %FunctionResult{}
   │         │   ├─ Process 2: ToolAgent.execute(pid, call_2) → %FunctionResult{}
   │         │   └─ Process N: ...
   │         │
   │         ├─ process: classify results (ok → observation, crash → error observation)
   │         │
   │         └─ feed_back: merge + package as %Message{role: :tool, content: [...]}
   │
   │  ◀── {:ok, result_message, observations}
   │
   THINK ─▶ ModelClient.create() with full history ──HTTP──▶ OpenAI API
   │                                                              │
   │  ◀── {:ok, %Message{content: "It's sunny in Tokyo!"}}
   │
   ACT ──▶ Return {:ok, generated_messages}

3. Caller extracts List.last(generated).content
```

## Concurrency Model Comparison

### Python (AutoGen)

```python
# Single-threaded event loop — cooperative multitasking
results = await asyncio.gather(
    caller.send_message(call1, recipient=tool_agent_id),
    caller.send_message(call2, recipient=tool_agent_id),
    caller.send_message(call3, recipient=tool_agent_id),
)
```

- One OS thread, coroutines yield at `await` points
- If a tool does CPU-heavy work, it blocks everything
- No isolation — an unhandled exception kills the gather

### Elixir (AgentEx)

```elixir
# True parallelism — preemptive scheduling across all CPU cores
results =
  tool_calls
  |> Task.async_stream(&ToolAgent.execute(tool_agent, &1),
       timeout: 30_000,
       on_timeout: :kill_task
     )
  |> Enum.map(&handle_task_result/1)
```

- Each task runs in its own BEAM process (lightweight, ~2KB each)
- Preemptive scheduling — no task can starve others
- Process isolation — a crash in one task doesn't affect others
- Built-in timeout — tasks killed after 30 seconds
- Scales across all CPU cores automatically

## Swarm Message Flow

A multi-agent swarm request flows through the system like this:

```
1. User builds agents and messages
   agents = [planner, analyst]
   messages = [Message.user("Analyze AAPL")]

2. Swarm.run/4 starts — creates ToolAgent per Swarm.Agent

   ┌─────── Agent: "planner" ────────────────────────────────────────┐
   │                                                                  │
   │  THINK ─▶ ModelClient.create() with planner's system_message    │
   │  │         + tools: [transfer_to_analyst, transfer_to_user]     │
   │  │                                                               │
   │  │  ◀── {:ok, %Message{tool_calls: [transfer_to_analyst()]}}    │
   │  │                                                               │
   │  SENSE ─▶ Sensing.sense() — executes transfer tool              │
   │  │         → "Transferred to analyst"                            │
   │  │                                                               │
   │  ROUTE ─▶ Handoff.detect() finds "transfer_to_analyst"         │
   │           → switch to "analyst" agent                            │
   └──────────────────────────────────────────────────────────────────┘

   ┌─────── Agent: "analyst" ────────────────────────────────────────┐
   │                                                                  │
   │  THINK ─▶ ModelClient.create() with analyst's system_message    │
   │  │         + tools: [lookup_stock, transfer_to_planner]         │
   │  │         + full conversation history from planner              │
   │  │                                                               │
   │  │  ◀── {:ok, %Message{tool_calls: [lookup_stock("AAPL")]}}    │
   │  │                                                               │
   │  SENSE ─▶ Sensing.sense() — executes lookup_stock               │
   │  │         → "AAPL: $150.00"                                     │
   │  │                                                               │
   │  THINK ─▶ ModelClient.create() with stock data                  │
   │  │                                                               │
   │  │  ◀── {:ok, %Message{content: "AAPL analysis: ..."}}         │
   │  │                                                               │
   │  ACT ──▶ Text response → loop exits                             │
   └──────────────────────────────────────────────────────────────────┘

3. Swarm returns {:ok, generated_messages, nil}
   (nil = no HandoffMessage, terminated with text response)

   If termination: {:handoff, "user"} and analyst called transfer_to_user:
   → {:ok, generated_messages, %HandoffMessage{target: "user", source: "analyst"}}
```

## Memory Architecture

The 3-tier memory system uses OTP patterns for each tier:

### Per-Agent Isolation Strategy

Each memory tier implements agent isolation differently, leveraging the best
OTP/BEAM primitive for its use case:

| Tier | OTP Primitive | Isolation Key |
|---|---|---|
| Working Memory | Registry + DynamicSupervisor | `{agent_id, session_id}` process key |
| Persistent Memory | ETS + DETS | `{agent_id, key}` tuple key |
| Semantic Memory | HelixDB vectors | `agent_id` field, client-side filter |
| Knowledge Graph | HelixDB graph | Per-agent episodes, shared entities |

### Working Memory: Registry-Based Process Lookup

Each agent+session combination gets a dedicated GenServer, registered via
the `SessionRegistry`:

```
Registry Key: {agent_id, session_id}     Process
────────────────────────────────────     ──────────────────
{"analyst", "session-1"}          →     #PID<0.200.0>
{"analyst", "session-2"}          →     #PID<0.201.0>
{"writer", "session-1"}          →     #PID<0.202.0>
```

DynamicSupervisor manages process lifecycle — sessions are started on demand
and terminated when no longer needed.

### Persistent Memory: ETS Compound Keys

The singleton PersistentMemory.Store uses `{agent_id, key}` tuples as ETS keys:

```
ETS Key                           Value
──────────────────────────       ─────────────────────────────
{"analyst", "expertise"}    →    %Entry{value: "data analysis", type: "fact"}
{"analyst", "model"}        →    %Entry{value: "gpt-4o", type: "preference"}
{"writer", "style"}         →    %Entry{value: "concise", type: "preference"}
```

This allows `all(agent_id)` to scan only that agent's entries using ETS
pattern matching on the first tuple element.

### Context Builder: Parallel Tier Gathering

The ContextBuilder uses `Task.async` to gather from all tiers simultaneously,
with `rescue` clauses for graceful degradation:

```
Memory.build_context("analyst", "session-1")
     │
     ├── Task.async → gather_persistent("analyst")       → "expertise: data analysis"
     ├── Task.async → gather_knowledge_graph("analyst")  → "Known facts: ..."
     ├── Task.async → gather_semantic("analyst")         → "Related: ..."
     └── Task.async → gather_conversation("analyst")     → [{role, content}, ...]
     │
     └── Task.await_many → merge + truncate → LLM messages
```

### Memory Integration Points

Memory integrates at two levels in the agent framework:

```
ToolCallerLoop.run(memory: %{agent_id: "analyst", session_id: "sess-1"})
     │
     ├─ BEFORE THINK: Memory.build_context() → inject system messages
     ├─ BEFORE THINK: store user messages in working memory
     │
     ├─ [normal Sense-Think-Act loop]
     │
     └─ AFTER ACT: store assistant response in working memory


Swarm.run(memory: %{session_id: "swarm-sess-1"})
     │
     ├─ START: Memory.start_session(name, session_id) for each agent
     │
     ├─ PER AGENT THINK: Memory.build_context(name, session_id) → inject
     ├─ PER AGENT ACT: store response in agent's working memory
     │
     └─ END: Memory.stop_session(name, session_id) for each agent
```

For the full memory guide, see [Memory System](memory.md).
