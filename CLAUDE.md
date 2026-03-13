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

## Documentation
- `docs/overview.md` — Project overview, motivation, and quick start
- `docs/architecture.md` — OTP process architecture and AutoGen mapping
- `docs/features.md` — Feature breakdown with AutoGen comparisons
- `docs/modules.md` — Module reference (structs, functions, types)

## Module Layout
- `lib/agent_ex/message.ex` — Message types (system, user, assistant, tool calls, results)
- `lib/agent_ex/tool.ex` — Tool definition and execution
- `lib/agent_ex/tool_agent.ex` — GenServer that executes tools (AutoGen's ToolAgent)
- `lib/agent_ex/sensing.ex` — Sensing phase: intervene → dispatch → process → feed back
- `lib/agent_ex/intervention.ex` — Intervention behaviour + pipeline runner
- `lib/agent_ex/intervention/` — Built-in handlers (PermissionHandler, WriteGateHandler, LogHandler)
- `lib/agent_ex/tool_caller_loop.ex` — Core Sense-Think-Act loop with intervention support
- `lib/agent_ex/handoff.ex` — HandoffMessage + transfer tool generation + detection
- `lib/agent_ex/swarm.ex` — Multi-agent Swarm orchestrator with handoff routing
- `lib/agent_ex/model_client.ex` — LLM API client
- `lib/agent_ex/example.ex` — Usage example

## Development
- `mix deps.get` — install dependencies
- `mix compile` — compile
- `mix test` — run tests
- `iex -S mix` — interactive shell with project loaded
