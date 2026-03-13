# Module Reference

## AgentEx.Message

**File:** `lib/agent_ex/message.ex`
**AutoGen equivalent:** `LLMMessage` types (`SystemMessage`, `UserMessage`, `AssistantMessage`, etc.)

### Struct

```elixir
@enforce_keys [:role, :content]
defstruct [:role, :content, :source, :tool_calls]
```

| Field | Type | Description |
|---|---|---|
| `role` | `:system \| :user \| :assistant \| :tool` | Message role |
| `content` | `String.t() \| [FunctionResult.t()]` | Text or tool results |
| `source` | `String.t() \| nil` | Who sent it (e.g., `"user"`, `"assistant"`) |
| `tool_calls` | `[FunctionCall.t()] \| nil` | Tool calls from the LLM |

### Factory Functions

| Function | Creates |
|---|---|
| `Message.system(content)` | System prompt message |
| `Message.user(content, source \\ "user")` | User input message |
| `Message.assistant(content, source \\ "assistant")` | Assistant text response |
| `Message.assistant_tool_calls(calls, source)` | Assistant message with tool call requests |
| `Message.tool_results(results)` | Tool execution results message |

### Nested: FunctionCall

```elixir
@enforce_keys [:id, :name, :arguments]
defstruct [:id, :name, :arguments]
```

| Field | Type | Description |
|---|---|---|
| `id` | `String.t()` | Unique call identifier (from LLM) |
| `name` | `String.t()` | Tool name to invoke |
| `arguments` | `String.t()` | JSON-encoded arguments |

### Nested: FunctionResult

```elixir
@enforce_keys [:call_id, :name, :content]
defstruct [:call_id, :name, :content, is_error: false]
```

| Field | Type | Description |
|---|---|---|
| `call_id` | `String.t()` | Matches the `FunctionCall.id` |
| `name` | `String.t()` | Tool name that was executed |
| `content` | `String.t()` | Result string or error message |
| `is_error` | `boolean()` | Whether execution failed |

---

## AgentEx.Tool

**File:** `lib/agent_ex/tool.ex`
**AutoGen equivalent:** `FunctionTool` / `ToolSchema`

### Struct

```elixir
@enforce_keys [:name, :description, :parameters, :function]
defstruct [:name, :description, :parameters, :function, kind: :read]
```

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | `String.t()` | (required) | Tool identifier |
| `description` | `String.t()` | (required) | Human-readable description (sent to LLM) |
| `parameters` | `map()` | (required) | JSON Schema for input parameters |
| `function` | `(map() -> {:ok, term()} \| {:error, term()})` | (required) | Implementation |
| `kind` | `:read \| :write` | `:read` | Permission kind (like Linux `r--` / `rw-`) |

### Functions

#### `new(opts)`
Factory that validates all required keys are present.

#### `read?(tool) -> boolean()`
Returns `true` if the tool is read-only (sensing).

#### `write?(tool) -> boolean()`
Returns `true` if the tool has side effects (acting).

#### `to_schema(tool) -> map()`
Converts to OpenAI function-calling format:
```elixir
%{
  "type" => "function",
  "function" => %{
    "name" => "...",
    "description" => "...",
    "parameters" => %{...}
  }
}
```

#### `execute(tool, arguments) -> {:ok, term()} | {:error, String.t()}`
Invokes `tool.function` with the argument map. Rescues any exception and
returns `{:error, message}`.

---

## AgentEx.ToolAgent

**File:** `lib/agent_ex/tool_agent.ex`
**AutoGen equivalent:** `autogen_core.tool_agent.ToolAgent`

A GenServer that holds a registry of tools and executes them on demand.

### State

```elixir
%{tools: %{String.t() => Tool.t()}}
```

### Public API

#### `start_link(opts)`
Starts the GenServer. Options:
- `tools:` — list of `AgentEx.Tool` structs to register
- `name:` — optional process name for registration

#### `execute(agent, %FunctionCall{}) -> %FunctionResult{}`
Sends a tool call to the agent and waits for the result (synchronous).
Handles three error cases:
1. Unknown tool name
2. Invalid JSON in arguments
3. Tool function raises an exception

#### `list_tools(agent) -> [Tool.t()]`
Returns all registered tools.

#### `tools_map(agent) -> %{String.t() => Tool.t()}`
Returns the internal `%{name => tool}` map. Useful for passing to intervention handlers.

### GenServer Callbacks

- `init/1` — Builds `%{name => tool}` map from the tools list
- `handle_call({:execute, call}, ...)` — Looks up tool, decodes JSON args, executes
- `handle_call(:list_tools, ...)` — Returns tool list
- `handle_call(:tools_map, ...)` — Returns the raw tools map

---

## AgentEx.Sensing

**File:** `lib/agent_ex/sensing.ex`
**AutoGen equivalent:** The sensing logic inside `tool_agent_caller_loop`'s while-loop

The Sensing module implements the **Sense** phase of the Sense-Think-Act cycle.
In AutoGen, sensing is inlined within the loop. In AgentEx, it's extracted into
an explicit module with three clear steps.

### Types

```elixir
@type observation :: FunctionResult.t()
@type sense_result :: {:ok, Message.t(), [observation()]} | {:error, term()}
@type opts :: [
  timeout: pos_integer(),
  on_timeout: :kill_task | :exit,
  intervention: [Intervention.handler()],
  tools_map: %{String.t() => Tool.t()},
  intervention_context: Intervention.context()
]
```

### Functions

#### `sense(tool_agent, tool_calls, opts \\ []) -> {:ok, message, observations}`

The complete sensing phase: intervene → dispatch → process → feed back.

**Parameters:**

| Param | Type | Description |
|---|---|---|
| `tool_agent` | `pid() \| atom() \| {:via, ...}` | ToolAgent process reference |
| `tool_calls` | `[FunctionCall.t()]` | Tool calls from the LLM |
| `opts` | `keyword()` | Options (see below) |

**Options:**

| Option | Default | Description |
|---|---|---|
| `timeout` | `30_000` | Per-tool execution timeout (ms) |
| `on_timeout` | `:kill_task` | What to do when a tool times out |
| `intervention` | `[]` | List of intervention handlers |
| `tools_map` | `%{}` | `%{name => Tool.t()}` for `:kind` lookup |
| `intervention_context` | `%{iteration: 0, ...}` | Context passed to handlers |

**Returns:** `{:ok, result_message, observations}` where:
- `result_message` — `%Message{role: :tool}` ready for conversation history
- `observations` — raw list of `%FunctionResult{}` structs

#### `intervene(tool_calls, handlers, tools_map, context) -> {approved, rejected}`

Step 0: Run each call through the intervention pipeline. Returns approved calls
and a map of rejected/dropped results.

#### `dispatch(tool_agent, tool_calls, opts \\ []) -> [{:ok, result} | {:exit, reason}]`

Step 1: Send approved FunctionCalls to the ToolAgent in parallel via `Task.async_stream`.
Each call runs in its own isolated BEAM process.

Maps to AutoGen's:
```python
results = await asyncio.gather(
    *[caller.send_message(call, recipient=tool_agent_id) ...],
    return_exceptions=True,
)
```

#### `process(raw_results, tool_calls) -> [observation()]`

Step 2: Classify raw task results into observations.

| Input | Output | AutoGen equivalent |
|---|---|---|
| `{:ok, %FunctionResult{}}` | Successful observation | `isinstance(result, FunctionExecutionResult)` |
| `{:exit, reason}` | Error observation (`is_error: true`) | `isinstance(result, ToolException)` or `BaseException` |

Key difference: In AutoGen, unexpected `BaseException` is re-raised (crashes the loop).
In Elixir, process isolation means crashed tasks produce `{:exit, reason}` —
the error becomes an observation, the loop continues.

#### `feed_back(observations) -> Message.t()`

Step 3: Package observations as a `%Message{role: :tool}` ready to append
to the conversation history for the next LLM call.

---

## AgentEx.ToolCallerLoop

**File:** `lib/agent_ex/tool_caller_loop.ex`
**AutoGen equivalent:** `autogen_core.tool_agent.tool_agent_caller_loop`

Stateless module that orchestrates the Sense-Think-Act cycle.
Uses `AgentEx.Sensing` for the sensing phase.

### Functions

#### `run(tool_agent, model_client, input_messages, tools, opts \\ [])`

**Parameters:**

| Param | Type | Description |
|---|---|---|
| `tool_agent` | `pid() \| atom() \| {:via, ...}` | ToolAgent process reference |
| `model_client` | `ModelClient.t()` | LLM API client |
| `input_messages` | `[Message.t()]` | Initial conversation history |
| `tools` | `[Tool.t()]` | Available tools |
| `opts` | `keyword()` | Options (see below) |

**Options:**

| Option | Default | Description |
|---|---|---|
| `max_iterations` | `10` | Max sensing rounds before stopping |
| `caller_source` | `"assistant"` | Source label for assistant messages |
| `tool_timeout` | `30_000` | Per-tool execution timeout (ms) |
| `intervention` | `[]` | List of intervention handlers (modules or functions) |
| `memory` | `nil` | `%{agent_id: "...", session_id: "..."}` for per-agent memory |

**Returns:** `{:ok, [Message.t()]} | {:error, term()}`

The last message in the returned list is the final text response from the LLM.

### Internal Loop

The private `loop/3` is tail-recursive with three exit conditions:

1. **ACT** — LLM returned text (no `tool_calls`) → return accumulated messages
2. **STOP** — Hit `max_iterations` → return what we have
3. **SENSE + THINK** — LLM wants tools → `Sensing.sense()` then re-query LLM → recurse

---

## AgentEx.ModelClient

**File:** `lib/agent_ex/model_client.ex`
**AutoGen equivalent:** `ChatCompletionClient`

### Struct

```elixir
@enforce_keys [:model]
defstruct [:model, :api_key, base_url: "https://api.openai.com/v1"]
```

| Field | Type | Default | Description |
|---|---|---|---|
| `model` | `String.t()` | (required) | Model identifier |
| `api_key` | `String.t() \| nil` | `nil` | API key (falls back to env var) |
| `base_url` | `String.t()` | `"https://api.openai.com/v1"` | API base URL |

### Functions

#### `new(opts)`
Factory function.

#### `create(client, messages, opts \\ [])`
Sends a chat completion request.

**Options:**
- `tools:` — list of `Tool.t()` to include as available tools

**Returns:**
- `{:ok, %Message{role: :assistant, content: "..."}}` — text response
- `{:ok, %Message{role: :assistant, tool_calls: [...]}}` — tool call request
- `{:error, reason}` — API or network error

### Message Encoding

Handles three message formats for the OpenAI API:

1. **Tool result messages** (`:tool` role) — expanded to per-result messages
   with `tool_call_id`
2. **Assistant tool-call messages** — include `tool_calls` array with
   function name and JSON arguments
3. **Standard messages** — simple `{role, content}` objects

### API Key Resolution

1. If `api_key` is provided in the struct → use it
2. Otherwise → read `OPENAI_API_KEY` environment variable
3. If neither → empty string (will fail at API)

---

## AgentEx.Intervention

**File:** `lib/agent_ex/intervention.ex`
**AutoGen equivalent:** `DefaultInterventionHandler`

Behaviour for tool call interception + pipeline runner.

### Types

```elixir
@type decision :: :approve | :reject | :drop | {:modify, FunctionCall.t()}
@type context :: %{iteration: non_neg_integer(), generated_messages: [Message.t()]}
@type handler :: module() | (FunctionCall.t(), Tool.t() | nil, context() -> decision())
```

### Callback

#### `on_call(call, tool, context) -> decision()`

Called before each tool call. Return `:approve`, `:reject`, `:drop`, or
`{:modify, new_call}`.

### Functions

#### `run_pipeline(handlers, call, tool, context) -> decision()`

Run a list of handlers in order. First non-`:approve` decision wins (short-circuit).

---

## AgentEx.Intervention.PermissionHandler

**File:** `lib/agent_ex/intervention/permission_handler.ex`

Module-based handler. Auto-approves `:read` tools, rejects all `:write` tools.
Like `chmod 444` — everything is read-only.

```elixir
AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
  intervention: [AgentEx.Intervention.PermissionHandler]
)
```

---

## AgentEx.Intervention.WriteGateHandler

**File:** `lib/agent_ex/intervention/write_gate_handler.ex`

Function-based handler factory. Creates a closure that approves `:read` tools
and only allows specific `:write` tools.

#### `new(opts) -> handler function`

**Options:**
- `allowed_writes:` — list of tool names permitted to write

```elixir
gate = AgentEx.Intervention.WriteGateHandler.new(allowed_writes: ["send_email"])
# gate is a function — pass it directly in the intervention list
```

Permission model:

| Tool kind | In allowlist? | Decision |
|---|---|---|
| `:read` | n/a | `:approve` |
| `:write` | yes | `:approve` |
| `:write` | no | `:reject` |
| unknown (`nil`) | n/a | `:approve` |

---

## AgentEx.Intervention.LogHandler

**File:** `lib/agent_ex/intervention/log_handler.ex`

Module-based handler. Logs every tool call (name, kind, args, iteration) and
always approves. Useful for audit trails.

```elixir
# Combine with other handlers — LogHandler goes first to log everything
intervention: [AgentEx.Intervention.LogHandler, gate]
```

---

## AgentEx.Handoff

**File:** `lib/agent_ex/handoff.ex`
**AutoGen equivalent:** `HandoffMessage` + `transfer_to_*()` tool generation

Transfer tool generation and handoff detection for multi-agent collaboration.

### Nested: HandoffMessage

```elixir
@enforce_keys [:target]
defstruct [:target, :content, :source, context: []]
```

| Field | Type | Default | Description |
|---|---|---|---|
| `target` | `String.t()` | (required) | Name of the agent to hand off to |
| `content` | `String.t() \| nil` | `nil` | Human-readable reason for the handoff |
| `source` | `String.t() \| nil` | `nil` | Who initiated the handoff |
| `context` | `[Message.t()]` | `[]` | Optional conversation history to pass along |

### Functions

#### `transfer_tool(target_name) -> Tool.t()`

Generate a single transfer tool for a target agent name.
The tool is `:write` kind with name `"transfer_to_<target>"`.

```elixir
tool = Handoff.transfer_tool("analyst")
tool.name  #=> "transfer_to_analyst"
tool.kind  #=> :write
```

#### `transfer_tools(target_names) -> [Tool.t()]`

Generate transfer tools for a list of target names.

```elixir
tools = Handoff.transfer_tools(["analyst", "writer"])
#=> [%Tool{name: "transfer_to_analyst", ...}, %Tool{name: "transfer_to_writer", ...}]
```

#### `transfer?(call) -> boolean()`

Check if a `FunctionCall` is a handoff transfer (name starts with `"transfer_to_"`).

#### `target(call) -> String.t() | nil`

Extract the target agent name from a transfer `FunctionCall`. Returns `nil` if
the call is not a transfer.

```elixir
call = %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
Handoff.target(call)  #=> "analyst"
```

#### `detect(tool_calls) -> {:handoff, target, call} | :none`

Scan a list of tool calls for a handoff. Returns the first transfer found.

```elixir
Handoff.detect([weather_call, transfer_call])
#=> {:handoff, "analyst", %FunctionCall{...}}

Handoff.detect([weather_call])
#=> :none
```

#### `prefix() -> String.t()`

Returns the transfer tool name prefix (`"transfer_to_"`).

---

## AgentEx.Swarm

**File:** `lib/agent_ex/swarm.ex`
**AutoGen equivalent:** `Swarm` / `SwarmTeam`

Multi-agent orchestration via handoffs.

### Nested: Swarm.Agent

```elixir
@enforce_keys [:name, :system_message]
defstruct [:name, :system_message, tools: [], handoffs: []]
```

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | `String.t()` | (required) | Unique agent identifier |
| `system_message` | `String.t()` | (required) | System prompt for this agent |
| `tools` | `[Tool.t()]` | `[]` | Agent's own tools |
| `handoffs` | `[String.t()]` | `[]` | Names of agents this agent can transfer to |

#### `Agent.new(opts) -> Agent.t()`

Factory function:

```elixir
agent = Swarm.Agent.new(
  name: "analyst",
  system_message: "You analyze data.",
  tools: [stock_tool],
  handoffs: ["planner", "user"]
)
```

### Functions

#### `run(agents, model_client, messages, opts \\ []) -> {:ok, messages, handoff} | {:error, reason}`

Run the multi-agent swarm.

**Parameters:**

| Param | Type | Description |
|---|---|---|
| `agents` | `[Swarm.Agent.t()]` | List of agents in the swarm |
| `model_client` | `ModelClient.t()` | LLM API client |
| `messages` | `[Message.t()]` | Initial conversation (user's question) |
| `opts` | `keyword()` | Options (see below) |

**Options:**

| Option | Default | Description |
|---|---|---|
| `start` | (required) | Name of the starting agent |
| `termination` | `:text_response` | `{:handoff, "user"}` or `:text_response` |
| `max_iterations` | `20` | Max iterations across all agents |
| `intervention` | `[]` | Intervention handlers for ALL tool calls |
| `model_fn` | `nil` | Override for `ModelClient.create` (testing) |
| `memory` | `nil` | `%{session_id: "..."}` for per-agent memory (agent name = agent_id) |

**Returns:** `{:ok, generated_messages, handoff_message_or_nil}`

- `generated_messages` — all messages generated during the swarm run
- `handoff_message_or_nil` — `%HandoffMessage{}` if terminated by handoff, `nil` if text response

**Errors:**
- `{:error, {:unknown_agent, name}}` — start agent or handoff target not found
- `{:error, reason}` — LLM API error

### Internal Loop

The private `swarm_loop/5` is tail-recursive with these exit conditions:

1. **TEXT** — Current agent returns text → return messages, `nil` handoff
2. **HANDOFF + TERMINATION** — Transfer to termination target → return messages + `HandoffMessage`
3. **HANDOFF + CONTINUE** — Transfer to another agent → switch and recurse
4. **TOOL CALLS** — Regular tools (no handoff) → Sensing.sense, continue with same agent
5. **MAX ITERATIONS** — Safety limit reached → return what we have

---

## AgentEx.Application

**File:** `lib/agent_ex/application.ex`

OTP Application module. Starts:
- `AgentEx.Registry` — unique-key process registry for named agent lookup
- `AgentEx.Memory.SessionRegistry` — working memory session lookup
- `AgentEx.Memory.WorkingMemory.Supervisor` — DynamicSupervisor for session GenServers
- `AgentEx.Memory.PersistentMemory.Store` — ETS + DETS key-value store
- `AgentEx.Memory.SemanticMemory.Store` — HelixDB vector client
- `AgentEx.Memory.KnowledgeGraph.Store` — graph operations
- `AgentEx.Supervisor` — `:one_for_one` supervisor

---

## AgentEx.Memory

**File:** `lib/agent_ex/memory.ex`

Public API facade for the 3-tier memory system. All functions take `agent_id`
as their first parameter for per-agent isolation.

### Session Management (Tier 1)

| Function | Description |
|---|---|
| `start_session(agent_id, session_id, opts \\ [])` | Start a working memory session (spawns GenServer) |
| `stop_session(agent_id, session_id)` | Stop and clean up a session |
| `add_message(agent_id, session_id, role, content)` | Add a message to conversation history |
| `get_messages(agent_id, session_id)` | Get all messages for a session |
| `get_recent_messages(agent_id, session_id, n)` | Get last N messages |

### Persistent Memory (Tier 2)

| Function | Description |
|---|---|
| `remember(agent_id, key, value, type \\ "preference")` | Store a key-value fact |
| `recall(agent_id, key)` | Retrieve a fact → `{:ok, entry}` or `:not_found` |
| `recall_by_type(agent_id, type)` | Get all facts of a type |
| `forget(agent_id, key)` | Delete a fact |

### Semantic Memory (Tier 3)

| Function | Description |
|---|---|
| `store_memory(agent_id, text, type \\ "general", session_id \\ "")` | Embed and store text |
| `search_memory(agent_id, query, limit \\ 5)` | Semantic search by similarity |

### Knowledge Graph

| Function | Description |
|---|---|
| `ingest(agent_id, text, role \\ "user")` | Run full extraction pipeline on a conversation turn |
| `query_entity(name)` | Query an entity by name (shared across agents) |
| `query_related(name, hops \\ 1)` | Graph traversal from an entity |
| `hybrid_search(agent_id, query, limit \\ 5)` | Combined vector + graph retrieval |

### Context Building

| Function | Description |
|---|---|
| `build_context(agent_id, session_id, opts \\ [])` | Compose all tiers → LLM-ready messages |

Options for `build_context`:
- `semantic_query:` — text to use for semantic/KG retrieval (default: `""`)
- `budgets:` — map of token budgets per tier (see [Memory System](memory.md))

---

## AgentEx.Memory.WorkingMemory.Server

**File:** `lib/agent_ex/memory/working_memory/server.ex`

Per-agent, per-session GenServer holding conversation history.

### State

```elixir
%{agent_id: String.t(), session_id: String.t(), messages: [Message.t()], max_messages: pos_integer()}
```

### Registration

```elixir
{:via, Registry, {AgentEx.Memory.SessionRegistry, {agent_id, session_id}}}
```

### Functions

| Function | Description |
|---|---|
| `add_message(agent_id, session_id, role, content)` | Append message, evict oldest if over limit |
| `get_messages(agent_id, session_id)` | All messages in chronological order |
| `get_recent(agent_id, session_id, n)` | Last N messages |
| `clear(agent_id, session_id)` | Remove all messages |
| `to_context_messages(agent_id, session_id)` | Format as `[%{role: ..., content: ...}]` |
| `token_estimate(agent_id, session_id)` | Approximate token count (`length / 4`) |
| `whereis(agent_id, session_id)` | Find PID or nil |

---

## AgentEx.Memory.PersistentMemory.Store

**File:** `lib/agent_ex/memory/persistent_memory/store.ex`

Singleton GenServer with ETS for fast reads and DETS for disk persistence.

### ETS Key Format

```elixir
{agent_id, key} => %Entry{key: key, value: value, type: type, ...}
```

### Functions

| Function | Description |
|---|---|
| `put(agent_id, key, value, type)` | Store/update an entry |
| `get(agent_id, key)` | Retrieve → `{:ok, entry}` or `:not_found` |
| `get_by_type(agent_id, type)` | All entries of a type for an agent |
| `delete(agent_id, key)` | Remove an entry |
| `all(agent_id)` | All entries for an agent |
| `to_context_messages(agent_id)` | Format as system message |

### Crash Recovery

On init: open DETS → create ETS → hydrate ETS from DETS → schedule periodic sync.
On crash: supervisor restarts → init rehydrates from DETS automatically.

---

## AgentEx.Memory.SemanticMemory.Store

**File:** `lib/agent_ex/memory/semantic_memory/store.ex`

GenServer that embeds text via OpenAI and stores/searches vectors in HelixDB.

### Functions

| Function | Description |
|---|---|
| `store(agent_id, text, type, session_id)` | Embed text → store vector in HelixDB |
| `search(agent_id, query, limit)` | Embed query → vector search → filter by agent_id |
| `to_context_messages(agent_id, query)` | Search and format as system message |

### Agent Isolation

Vectors are tagged with `agent_id` on storage. On search, the store over-fetches
`limit * 3` results from HelixDB, then filters client-side to only return
results matching the requesting agent's ID.

---

## AgentEx.Memory.KnowledgeGraph.Store

**File:** `lib/agent_ex/memory/knowledge_graph/store.ex`

Orchestrates the knowledge graph ingestion pipeline and retrieval.

### Functions

| Function | Description |
|---|---|
| `ingest(agent_id, text, role)` | Full pipeline: episode → extract → resolve → store |
| `query_entity(name)` | Find entity by name (shared) |
| `query_related(name, hops)` | Graph traversal from entity |
| `hybrid_search(agent_id, query, limit)` | Combined vector + graph retrieval |
| `to_context_messages(agent_id, query)` | Format graph knowledge as system message |

---

## AgentEx.Memory.KnowledgeGraph.Extractor

**File:** `lib/agent_ex/memory/knowledge_graph/extractor.ex`

LLM-based entity and relationship extraction. Reuses `AgentEx.ModelClient`
for API calls.

### Functions

| Function | Description |
|---|---|
| `extract(text)` | Send to LLM → parse JSON → return entities + relationships |

Uses the `extraction_model` config (default: `gpt-4o-mini`) with
`temperature: 0.0` and `response_format: json_object`.

### Extracted Types

- **Entities**: `{name, type, description}` where type is PERSON, ORGANIZATION, CONCEPT, EVENT, ARTIFACT, or PREFERENCE
- **Relationships**: `{source, target, type, description, confidence}` where confidence is HIGH, MEDIUM, or LOW

---

## AgentEx.Memory.KnowledgeGraph.Retriever

**File:** `lib/agent_ex/memory/knowledge_graph/retriever.ex`

Hybrid retrieval combining vector search and graph traversal.

### Functions

| Function | Description |
|---|---|
| `retrieve(agent_id, query, limit)` | Run 3 parallel strategies, merge + rank results |

### Strategies (run in parallel via `Task.async`)

1. **Episode search**: Embed query → `SearchEpisodes` → filter by agent_id
2. **Entity traversal**: Embed query → `FindEntity` → `GetEntityKnowledge`
3. **Fact search**: Embed query → `SearchFacts`

---

## AgentEx.Memory.ContextBuilder

**File:** `lib/agent_ex/memory/context_builder.ex`

Composes all memory tiers into LLM-ready messages with token budgets.

### Functions

| Function | Description |
|---|---|
| `build(agent_id, session_id, opts)` | Gather all tiers in parallel → truncate → compose |

### Default Token Budgets

| Tier | Budget |
|---|---|
| Persistent | 500 |
| Knowledge Graph | 1000 |
| Semantic | 500 |
| Conversation | 4000 |
| Total | 8000 |

---

## Memory Structs

### AgentEx.Memory.Message

**File:** `lib/agent_ex/memory/message.ex`

Timestamped conversation message for working memory.

```elixir
%{role: String.t(), content: String.t(), timestamp: DateTime.t(), metadata: map()}
```

### AgentEx.Memory.Entry

**File:** `lib/agent_ex/memory/entry.ex`

Persistent memory entry.

```elixir
%{key: String.t(), value: String.t(), type: String.t(),
  created_at: DateTime.t(), updated_at: DateTime.t(), metadata: map()}
```

### AgentEx.Memory.ContextMessage

**File:** `lib/agent_ex/memory/context_message.ex`

LLM context message with factory functions.

```elixir
%{role: String.t(), content: String.t()}
```

| Function | Creates |
|---|---|
| `ContextMessage.system(content)` | System message |
| `ContextMessage.user(content)` | User message |
| `ContextMessage.assistant(content)` | Assistant message |
