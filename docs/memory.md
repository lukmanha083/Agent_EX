# Memory System

AgentEx includes a 3-tier memory system with knowledge graph, designed for
multi-agent architectures where each agent needs its own isolated memory space.

## Architecture

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

All operations are scoped by `agent_id` — each agent gets its own isolated
memory. Multiple agents can share a `session_id` while maintaining separate
memory spaces.

## Per-Agent Isolation

The core design principle: **every memory operation takes `agent_id` as its
first parameter**. This means:

- Working memory sessions are keyed by `{agent_id, session_id}`
- Persistent memory entries are keyed by `{agent_id, key}` in ETS/DETS
- Semantic memory vectors are tagged with `agent_id` and filtered on search
- Knowledge graph episodes are per-agent; entities and facts are shared

```elixir
# Two agents, same session — completely isolated memories
Memory.start_session("analyst", "session-1")
Memory.start_session("writer", "session-1")

Memory.add_message("analyst", "session-1", "user", "Analyze AAPL")
Memory.add_message("writer", "session-1", "user", "Write a report")

Memory.get_messages("analyst", "session-1")  # only "Analyze AAPL"
Memory.get_messages("writer", "session-1")   # only "Write a report"
```

## Tier 1: Working Memory

Short-term conversation history. Each agent+session pair gets a dedicated
GenServer process managed by a DynamicSupervisor.

**OTP implementation**: Per-session GenServer registered via
`{:via, Registry, {SessionRegistry, {agent_id, session_id}}}`.

```elixir
alias AgentEx.Memory

# Start a session (spawns a GenServer)
{:ok, _pid} = Memory.start_session("analyst", "session-1")

# Optionally set max message limit (default from config)
{:ok, _pid} = Memory.start_session("analyst", "session-2", max_messages: 50)

# Add messages
Memory.add_message("analyst", "session-1", "user", "Analyze AAPL stock")
Memory.add_message("analyst", "session-1", "assistant", "AAPL is trading at $150...")

# Retrieve messages
messages = Memory.get_messages("analyst", "session-1")
# => [%{role: "user", content: "Analyze AAPL stock", timestamp: ...}, ...]

# Get last N messages
recent = Memory.get_recent_messages("analyst", "session-1", 5)

# Clean up (terminates the GenServer)
Memory.stop_session("analyst", "session-1")
```

**Automatic eviction**: When message count exceeds `max_messages`, oldest
messages are dropped (sliding window).

## Tier 2: Persistent Memory

Long-term key-value facts that survive process restarts. Uses ETS for fast
reads and DETS for disk persistence, with periodic sync.

**OTP implementation**: Singleton GenServer. ETS keys are `{agent_id, key}`
tuples for per-agent isolation. DETS rehydrates ETS on restart.

```elixir
alias AgentEx.Memory

# Store facts about an agent
Memory.remember("analyst", "expertise", "financial data analysis", "fact")
Memory.remember("analyst", "preferred_model", "gpt-4o", "preference")
Memory.remember("writer", "style", "concise and technical", "preference")

# Recall a specific fact
{:ok, entry} = Memory.recall("analyst", "expertise")
entry.value  #=> "financial data analysis"
entry.type   #=> "fact"

# Recall by type (returns all matching entries for that agent)
prefs = Memory.recall_by_type("analyst", "preference")
# => [%{key: "preferred_model", value: "gpt-4o", type: "preference", ...}]

# Memory is agent-isolated
:not_found = Memory.recall("writer", "expertise")  # writer doesn't have this

# Forget a fact
Memory.forget("analyst", "preferred_model")

# Crash resilience: if the Store process crashes, the supervisor restarts
# it and DETS rehydrates ETS automatically
```

## Tier 3: Semantic Memory

Vector-based semantic search using OpenAI embeddings and HelixDB. Store text
with embeddings, search by semantic similarity.

**Requires**: HelixDB running at `localhost:6969`, `OPENAI_API_KEY` set.

```elixir
alias AgentEx.Memory

# Store text (embeds via OpenAI, stores vector in HelixDB)
Memory.store_memory("analyst", "AAPL P/E ratio is 28.5 as of March 2026", "analysis")
Memory.store_memory("analyst", "MSFT revenue grew 15% YoY", "analysis")

# Semantic search (embeds query, searches HelixDB, filters by agent_id)
results = Memory.search_memory("analyst", "Apple stock valuation", 5)
# => [%{"content" => "AAPL P/E ratio is 28.5...", "score" => 0.87, ...}]

# Agent isolation: writer can't see analyst's memories
results = Memory.search_memory("writer", "Apple stock valuation", 5)
# => []
```

**How agent isolation works**: Vectors are tagged with `agent_id` on storage.
On search, we over-fetch 3x the limit from HelixDB, then filter client-side
by `agent_id` before returning results.

## Knowledge Graph

Entity/relationship extraction via LLM, stored as a graph in HelixDB. Enables
hybrid retrieval combining vector search and graph traversal.

**Requires**: HelixDB running, `OPENAI_API_KEY` set.

### Ingestion

When a conversation turn arrives, the ingestion pipeline:

1. Creates an Episode node (per-agent) with embedding
2. Sends text to LLM for entity/relationship extraction
3. Resolves entities (merge or create) via vector similarity
4. Stores facts as edges between entities with embeddings
5. Links entities to the episode for provenance

```elixir
alias AgentEx.Memory

# Ingest a conversation turn (runs full extraction pipeline)
Memory.ingest("analyst", "The team switched from Jest to Vitest for testing", "user")
# Creates: Entity(Jest), Entity(Vitest), Fact(switched_from), Episode(...)

# Query entities (shared across agents)
Memory.query_entity("Vitest")
# => %{name: "Vitest", type: "ARTIFACT", description: "Testing framework", ...}

# Query related entities (graph traversal)
Memory.query_related("Vitest", 2)  # 2-hop traversal

# Hybrid search (vector + graph, agent-scoped episodes)
results = Memory.hybrid_search("analyst", "testing framework", 5)
```

### Retrieval

Hybrid search runs three strategies in parallel:

1. **Vector search**: Embed query → search episode embeddings (agent-scoped)
2. **Entity traversal**: Extract entities from query → graph traversal (shared)
3. **Fact search**: Embed query → search fact embeddings (shared)

Results are merged, deduplicated, and ranked by recency + confidence.

### Entity types

The extractor recognizes: `PERSON`, `ORGANIZATION`, `CONCEPT`, `EVENT`,
`ARTIFACT`, `PREFERENCE`.

### Entity resolution

When a new entity is extracted, the system embeds its name+description and
searches existing entities via vector similarity. If similarity > 0.85, the
existing entity is reused (merged). Otherwise, a new entity is created.

## Context Builder

The `ContextBuilder` gathers all memory tiers in parallel and composes them
into an LLM-ready message list with token budgets.

```elixir
alias AgentEx.Memory

# Build context manually
messages = Memory.build_context("analyst", "session-1",
  semantic_query: "stock analysis",
  budgets: %{persistent: 500, knowledge_graph: 1000, semantic: 500, conversation: 4000}
)
# => [
#   %{role: "system", content: "## User Preferences\n- expertise: financial..."},
#   %{role: "user", content: "Analyze AAPL"},
#   %{role: "assistant", content: "AAPL is..."}
# ]
```

### Token budgets (defaults)

| Source | Budget (tokens) |
|---|---|
| Persistent memory | 500 |
| Knowledge graph | 1000 |
| Semantic memory | 500 |
| Conversation history | 4000 |
| Total | 8000 |

Token estimation uses `string_length / 4` as an approximation.

### What gets included

The context builder produces a system message containing:

```
## User Preferences
- expertise: financial data analysis (fact)
- preferred_model: gpt-4o (preference)

## Knowledge Graph
Known facts:
- Lukman works_at Acme Corp (HIGH confidence)
- Elixir depends_on BEAM (HIGH confidence)
Related context:
- Acme Corp is building an AI agent platform

## Relevant Past Context
- [Mar 10] Discussed GenServer patterns for agent state
```

Followed by conversation history messages from working memory.

## Integration with ToolCallerLoop

The tool-calling loop optionally accepts a `:memory` option. When set, it
automatically injects memory context and stores conversation turns.

```elixir
alias AgentEx.{Memory, ToolCallerLoop, ToolAgent, ModelClient}

# 1. Start a memory session for this agent
{:ok, _} = Memory.start_session("analyst", "session-1")

# 2. Store some persistent facts
Memory.remember("analyst", "expertise", "financial analysis", "fact")

# 3. Run the tool-calling loop with memory enabled
{:ok, agent} = ToolAgent.start_link(tools: tools)
client = ModelClient.new(model: "gpt-4o")

{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools,
  memory: %{agent_id: "analyst", session_id: "session-1"}
)

# What happens automatically:
# - Before first THINK: builds context from all memory tiers, injects as
#   system messages after any existing system messages
# - User messages from input are stored in working memory
# - Final assistant text response is stored in working memory
# - Semantic query hint is extracted from the last user message

# 4. Clean up
Memory.stop_session("analyst", "session-1")
```

### Memory option type

```elixir
@type memory_opts :: %{agent_id: String.t(), session_id: String.t()}
```

### What the loop does with memory

| Phase | Action |
|---|---|
| Before first THINK | `Memory.build_context/3` → injects system messages |
| Before first THINK | Stores user messages in working memory |
| After final ACT | Stores assistant response in working memory |

## Integration with Swarm

The Swarm orchestrator accepts a `:memory` option. When set, each agent in the
swarm automatically gets its own memory session, using the agent's `name` as
its `agent_id`.

```elixir
alias AgentEx.{Memory, Swarm, ModelClient, Message}

# Store persistent facts for specific agents
Memory.remember("analyst", "expertise", "data analysis", "fact")
Memory.remember("writer", "style", "concise", "preference")

# Run the swarm with memory
{:ok, msgs, handoff} = Swarm.run(
  [planner, analyst, writer],
  ModelClient.new(model: "gpt-4o"),
  [Message.user("Write a report on AAPL")],
  start: "planner",
  termination: {:handoff, "user"},
  memory: %{session_id: "swarm-session-1"}
)

# What happens automatically:
# - At start: Memory.start_session(name, session_id) for each agent
# - Before each THINK: Memory.build_context(name, session_id) injected
# - After each text response: stored in that agent's working memory
# - At end: Memory.stop_session(name, session_id) for each agent
```

### Swarm memory option type

```elixir
# Note: no agent_id — each agent uses its name
memory: %{session_id: String.t()}
```

### How agents are scoped

| Agent name | agent_id used | session_id |
|---|---|---|
| `"planner"` | `"planner"` | `"swarm-session-1"` |
| `"analyst"` | `"analyst"` | `"swarm-session-1"` |
| `"writer"` | `"writer"` | `"swarm-session-1"` |

Each agent only sees its own persistent memory, working memory, and semantic
search results. The knowledge graph entities are shared (useful for agents
that collaborate on the same domain).

## Configuration

Configuration is in `config/`:

```elixir
# config/config.exs (defaults)
config :agent_ex,
  helix_db_url: "http://localhost:6969",
  embedding_model: "text-embedding-3-small",
  extraction_model: "gpt-4o-mini"

# config/runtime.exs (secrets from environment)
config :agent_ex,
  openai_api_key: System.get_env("OPENAI_API_KEY")

# config/dev.exs
config :agent_ex,
  max_messages: 100,
  sync_interval: 30_000,
  dets_dir: "priv/data/dev"

# config/test.exs
config :agent_ex,
  max_messages: 50,
  sync_interval: 60_000,
  dets_dir: "priv/data/test"
```

### Environment variables

| Variable | Required for | Description |
|---|---|---|
| `OPENAI_API_KEY` | Tier 3, Knowledge Graph | OpenAI API key for embeddings and extraction |
| `HELIX_DB_URL` | Tier 3, Knowledge Graph | HelixDB endpoint (default: `http://localhost:6969`) |

## Supervision Tree

The memory system adds these processes to the OTP supervision tree:

```
AgentEx.Supervisor (:one_for_one)
├── AgentEx.Registry                           — Agent framework
├── AgentEx.Memory.SessionRegistry             — Working memory lookup
├── AgentEx.Memory.WorkingMemory.Supervisor    — DynamicSupervisor
│   ├── WorkingMemory.Server {analyst, sess-1} — Per-session GenServer
│   ├── WorkingMemory.Server {writer, sess-1}  — Per-session GenServer
│   └── ...
├── AgentEx.Memory.PersistentMemory.Store      — ETS + DETS (singleton)
├── AgentEx.Memory.SemanticMemory.Store        — HelixDB vector client
└── AgentEx.Memory.KnowledgeGraph.Store        — Graph operations
```

## HelixDB Schema

The HelixDB schema lives in `helix/schema.hx` and `helix/queries.hx`. Push
the schema before using Tier 3 or Knowledge Graph features:

```bash
helix push dev
```

### Types defined

| Type | Purpose |
|---|---|
| `V::Memory` | Semantic memory vectors (Tier 3) |
| `V::EntityEmbedding` | Entity name+description embeddings |
| `V::EpisodeEmbedding` | Conversation episode embeddings |
| `V::FactEmbedding` | Relationship description embeddings |
| `N::Entity` | Knowledge graph entity nodes |
| `N::Episode` | Knowledge graph episode nodes |
| `E::Fact` | Relationship edges between entities |
| `E::MentionedIn` | Entity→Episode provenance edges |
| `E::HasEmbedding` | Entity→EntityEmbedding links |
| `E::HasEpisodeEmbedding` | Episode→EpisodeEmbedding links |
| `E::HasFactEmbedding` | Entity→FactEmbedding links |

## Graceful Degradation

Each tier degrades independently:

- **No HelixDB**: Tier 3 and Knowledge Graph return empty results; Tier 1 and 2 work fine
- **No OPENAI_API_KEY**: Tier 3 and Knowledge Graph return errors; Tier 1 and 2 work fine
- **Session not started**: Working memory calls fail; other tiers work fine
- **Process crash**: Supervisor restarts the crashed process; DETS rehydrates Tier 2

The ContextBuilder wraps each tier's gather function in `rescue` — if any
tier fails, it returns empty and the context is built from the remaining tiers.

## Module Reference

| Module | Description |
|---|---|
| `AgentEx.Memory` | Public API facade |
| `AgentEx.Memory.Tier` | Behaviour for all tiers |
| `AgentEx.Memory.WorkingMemory.Supervisor` | DynamicSupervisor for sessions |
| `AgentEx.Memory.WorkingMemory.Server` | Per-session conversation GenServer |
| `AgentEx.Memory.PersistentMemory.Store` | ETS + DETS key-value store |
| `AgentEx.Memory.PersistentMemory.Loader` | DETS/ETS hydration and sync |
| `AgentEx.Memory.SemanticMemory.Store` | Vector embed + search via HelixDB |
| `AgentEx.Memory.SemanticMemory.Client` | HelixDB HTTP client |
| `AgentEx.Memory.KnowledgeGraph.Store` | Ingestion pipeline orchestrator |
| `AgentEx.Memory.KnowledgeGraph.Extractor` | LLM entity/relationship extraction |
| `AgentEx.Memory.KnowledgeGraph.Retriever` | Hybrid graph+vector retrieval |
| `AgentEx.Memory.Embeddings` | OpenAI embedding API client |
| `AgentEx.Memory.ContextBuilder` | Compose all tiers → LLM messages |
| `AgentEx.Memory.Message` | Conversation message struct |
| `AgentEx.Memory.Entry` | Persistent memory entry struct |
| `AgentEx.Memory.ContextMessage` | LLM context message struct |
