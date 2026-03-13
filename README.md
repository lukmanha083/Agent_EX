# AgentEx

An Elixir/OTP reimplementation of [Microsoft AutoGen](https://github.com/microsoft/autogen)'s
core agent framework patterns, with a **3-tier memory system and knowledge graph**.

Built as a learning project to understand AI agent internals while leveraging
BEAM/OTP primitives — processes, supervision, ETS/DETS, and message passing.

## Features

- **Sense-Think-Act loop** — iterative tool-calling cycle between LLM and tools
- **Tool permissions** — `:read` / `:write` kind with Linux-style intervention pipeline
- **Multi-agent Swarm** — agent orchestration via handoffs and transfer tools
- **3-tier memory system** — working memory, persistent memory, semantic memory
- **Knowledge graph** — entity/relationship extraction with hybrid retrieval
- **Per-agent memory isolation** — each agent gets its own scoped memory space
- **True parallel execution** — BEAM processes for concurrent tool calls
- **Fault isolation** — crashed tools produce error observations, not crashes

## Quick Start

```elixir
# Single agent with tools
{:ok, agent} = AgentEx.ToolAgent.start_link(tools: [weather_tool])
client = AgentEx.ModelClient.new(model: "gpt-4o")

{:ok, result} = AgentEx.ToolCallerLoop.run(agent, client, messages, tools)

# With per-agent memory
AgentEx.Memory.start_session("analyst", "session-1")

{:ok, result} = AgentEx.ToolCallerLoop.run(agent, client, messages, tools,
  memory: %{agent_id: "analyst", session_id: "session-1"}
)

# Multi-agent swarm with memory
{:ok, msgs, handoff} = AgentEx.Swarm.run(agents, client, messages,
  start: "planner",
  termination: {:handoff, "user"},
  memory: %{session_id: "swarm-1"}
)
```

## Documentation

- [Overview](docs/overview.md) — project motivation, core concepts, quick start
- [Architecture](docs/architecture.md) — OTP process architecture and AutoGen mapping
- [Features](docs/features.md) — feature breakdown with AutoGen comparisons
- [Memory System](docs/memory.md) — 3-tier memory, knowledge graph, per-agent isolation
- [Module Reference](docs/modules.md) — structs, functions, types

## Development

```bash
mix deps.get      # install dependencies
mix compile       # compile
mix test          # run tests (103 tests)
iex -S mix        # interactive shell
```

## Dependencies

- **Req** — HTTP client for LLM APIs and HelixDB
- **Jason** — JSON encoding/decoding
- **HelixDB** — graph-vector database (localhost:6969) for Tier 3 + Knowledge Graph
- **OpenAI API** — embeddings (text-embedding-3-small) and extraction (gpt-4o-mini)
