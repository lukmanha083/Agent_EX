# AgentEx — AutoGen Core Patterns in Elixir/OTP

## Purpose
Reimplements AutoGen's core agent framework patterns using native BEAM/OTP primitives.
Companion to the Python learning project at `../agent/`.

## Tech Stack
- Elixir 1.18+ / Erlang/OTP 28
- Req (HTTP client for LLM APIs)
- Jason (JSON encoding/decoding)

## Architecture Mapping (AutoGen → Elixir)

| AutoGen (Python) | AgentEx (Elixir) |
|---|---|
| `ToolAgent` | `AgentEx.ToolAgent` (GenServer) |
| `tool_agent_caller_loop` | `AgentEx.ToolCallerLoop.run/5` |
| `ChatCompletionClient` | `AgentEx.ModelClient` |
| `Tool` / `ToolSchema` | `AgentEx.Tool` |
| `LLMMessage` types | `AgentEx.Message` structs |
| `AgentRuntime` | OTP Supervisor + Registry |
| `send_message()` | `GenServer.call/2` |
| `asyncio.gather` | `Task.async_stream` |
| Sensing phase (inline in loop) | `AgentEx.Sensing` (explicit module) |
| `DefaultInterventionHandler` | `AgentEx.Intervention` (behaviour + function handlers) |
| No tool kind distinction | `Tool.kind` `:read` / `:write` (Linux-style permissions) |
| `CancellationToken` | Process monitors + `Task.shutdown` |
| `HandoffMessage` | `AgentEx.Handoff.HandoffMessage` |
| `Swarm` / `SwarmTeam` | `AgentEx.Swarm` (multi-agent orchestrator) |
| `transfer_to_*()` tools | `AgentEx.Handoff.transfer_tools/1` (auto-generated) |
| `HandoffTermination` | `Swarm.run(termination: {:handoff, "user"})` |
| `ToolOverride` | `AgentEx.ToolOverride` (metadata wrapper, preserves kind) |
| Pydantic auto-schema | `AgentEx.ToolBuilder` (param hints + `deftool` macro) |
| `BaseToolWithState` | `AgentEx.StatefulTool` (wraps tool + PersistentMemory.Store) |
| `Workbench` | `AgentEx.Workbench` (GenServer, dynamic registry + versioning) |
| `StreamTool` / `run_json_stream` | `AgentEx.StreamTool` (emit/collect pattern) |
| `mcp_server_tools` | `AgentEx.MCP.Client` + `ToolAdapter` (stdio/HTTP transport) |
| Plugin system | `AgentEx.ToolPlugin` (behaviour) + `AgentEx.PluginRegistry` (lifecycle) |
| Pipeline composition | `AgentEx.Pipe` (through/fan_out/merge/route/delegate_tool) |
| Memory promotion | `AgentEx.Memory.Promotion` (session summaries + save_memory tool) |

## Documentation
- `docs/overview.md` — Project overview, motivation, and quick start
- `docs/architecture.md` — OTP process architecture and AutoGen mapping
- `docs/features.md` — Feature breakdown with AutoGen comparisons
- `docs/memory.md` — 3-tier memory system, knowledge graph, per-agent isolation
- `docs/modules.md` — Module reference (structs, functions, types)

## Module Layout

### Agent Framework
- `lib/agent_ex/message.ex` — Message types (system, user, assistant, tool calls, results)
- `lib/agent_ex/tool.ex` — Tool definition and execution
- `lib/agent_ex/tool_agent.ex` — GenServer that executes tools (AutoGen's ToolAgent)
- `lib/agent_ex/sensing.ex` — Sensing phase: intervene → dispatch → process → feed back
- `lib/agent_ex/intervention.ex` — Intervention behaviour + pipeline runner
- `lib/agent_ex/intervention/` — Built-in handlers (PermissionHandler, WriteGateHandler, LogHandler)
- `lib/agent_ex/tool_caller_loop.ex` — Core Sense-Think-Act loop with intervention support
- `lib/agent_ex/handoff.ex` — HandoffMessage + transfer tool generation + detection
- `lib/agent_ex/swarm.ex` — Multi-agent Swarm orchestrator with handoff routing
- `lib/agent_ex/model_client.ex` — LLM API client (also supports `temperature:` and `response_format:` opts)
- `lib/agent_ex/tool_override.ex` — Wrap tools with overridden metadata (name/description)
- `lib/agent_ex/tool_builder.ex` — Auto-generate JSON Schema from param specs + `deftool` macro
- `lib/agent_ex/stateful_tool.ex` — Tools with persistent state across sessions (via Tier 2)
- `lib/agent_ex/workbench.ex` — Dynamic tool collection GenServer with version tracking
- `lib/agent_ex/stream_tool.ex` — Streaming tool results with emit/collect pattern
- `lib/agent_ex/pipe.ex` — Pipe-based orchestration: through/fan_out/merge/route/delegate_tool
- `lib/agent_ex/tool_plugin.ex` — ToolPlugin behaviour for reusable tool bundles
- `lib/agent_ex/plugin_registry.ex` — Plugin lifecycle manager (attach/detach/list)
- `lib/agent_ex/plugins/file_system.ex` — Built-in sandboxed file operations plugin
- `lib/agent_ex/plugins/shell_exec.ex` — Built-in sandboxed shell execution plugin
- `lib/agent_ex/mcp/client.ex` — MCP JSON-RPC 2.0 client GenServer
- `lib/agent_ex/mcp/transport.ex` — Stdio and HTTP transport adapters for MCP
- `lib/agent_ex/mcp/tool_adapter.ex` — Convert MCP tools ↔ AgentEx tools
- `lib/agent_ex/example.ex` — Usage example

### 3-Tier Memory System + Knowledge Graph (`AgentEx.Memory`)
- `lib/agent_ex/memory.ex` — Public API facade
- `lib/agent_ex/memory/tier.ex` — `@behaviour` for all memory tiers (`to_context_messages/1`, `token_estimate/1`)
- `lib/agent_ex/memory/message.ex` — Timestamped conversation message (working memory)
- `lib/agent_ex/memory/entry.ex` — Persistent memory entry struct
- `lib/agent_ex/memory/context_message.ex` — LLM context message struct
- `lib/agent_ex/memory/working_memory/supervisor.ex` — DynamicSupervisor for per-session GenServers (Tier 1)
- `lib/agent_ex/memory/working_memory/server.ex` — Per-session conversation history (Tier 1)
- `lib/agent_ex/memory/persistent_memory/store.ex` — ETS + DETS key-value memory (Tier 2)
- `lib/agent_ex/memory/persistent_memory/loader.ex` — DETS ↔ ETS hydration/sync
- `lib/agent_ex/memory/semantic_memory/client.ex` — HelixDB HTTP client (shared)
- `lib/agent_ex/memory/semantic_memory/store.ex` — Vector embed + search (Tier 3)
- `lib/agent_ex/memory/knowledge_graph/store.ex` — Ingestion pipeline: extract → resolve → store
- `lib/agent_ex/memory/knowledge_graph/extractor.ex` — LLM entity/relationship extraction (reuses `ModelClient`)
- `lib/agent_ex/memory/knowledge_graph/retriever.ex` — Hybrid graph+vector retrieval (3 parallel strategies)
- `lib/agent_ex/memory/embeddings.ex` — OpenAI embedding API client
- `lib/agent_ex/memory/context_builder.ex` — Compose all tiers + KG into LLM prompt
- `lib/agent_ex/memory/promotion.ex` — Memory promotion: session summaries + save_memory tool
- `helix/schema.hx` — HelixDB vector/node/edge type definitions
- `helix/queries.hx` — HelixQL queries for CRUD + search

### Memory Architecture
```
┌──────────────────────────────────────────────────────────────┐
│                       ContextBuilder                          │
│  Gathers all tiers + knowledge graph → LLM-ready messages     │
└───┬────────────┬─────────────────┬────────────────┬──────────┘
    │            │                 │                │
┌───▼───┐  ┌────▼─────┐  ┌───────▼───────┐  ┌─────▼──────────┐
│ Tier 1 │  │  Tier 2   │  │    Tier 3      │  │ Knowledge Graph│
│Working │  │Persistent │  │   Semantic     │  │  (HelixDB      │
│Memory  │  │ Memory    │  │   Memory       │  │   Graph+Vector)│
│(GenSrv)│  │(ETS+DETS) │  │(HelixDB Vector)│  │                │
└────────┘  └──────────┘  └───────────────┘  └────────────────┘
```

## Development
- `mix deps.get` — install dependencies
- `mix compile` — compile
- `mix test` — run tests
- `iex -S mix` — interactive shell with project loaded
