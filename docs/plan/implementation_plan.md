# AgentEx Implementation Plan — Plugins, Pipes, Memory & LiveView UI

**Core Insight:** Every orchestration pattern is **function composition** — input
flows through a transform and becomes output. The pipe operator (`|>`) is the
unifying abstraction. The LLM is both a transform within pipes AND the reasoner
that decides which pipe pattern to compose.

```elixir
# The LLM composes workflows dynamically based on the task + memory
"Analyze AAPL stock"
|> Pipe.through(orchestrator, client)   # LLM plans the workflow
# orchestrator internally decides to:
#   1. fan_out to [web_researcher, financial_analyst]
#   2. merge results through consolidator
#   3. pipe through writer
# ...informed by Tier 3 memory of past successful workflows
```

**Status:** Phases 1–5 implemented. Auth + password registration
implemented (2026-03-22). Phase 4b (User Timezone + User Scoping) merged (2026-03-23).
Phase 4d (Dashboard Refactor) merged (2026-03-23). Phase 4c (Conversation History)
implemented (2026-03-25). Phase 5 (Agent Builder + Unified Tool Management) implemented
(2026-03-26). Intervention redesign: embedded in agent editor with per-handler config
(WriteGateHandler allowlist), sandbox boundary (root_path, disallowed commands) (2026-03-27).
Phase 5b (Chat Orchestrator + REST API Tools + Agent-as-Tool) next.
Phase 8 (Hybrid Bridge — Remote Computer Use) is the final phase.

**Table of Contents**

1. [Design Philosophy](#design-philosophy)
2. [Phase Dependency Graph](#phase-dependency-graph)
3. [Phase 1 — ToolPlugin Behaviour + Plugin Registry](#phase-1--toolplugin-behaviour--plugin-registry)
4. [Phase 2 — Memory Promotion + Session Context](#phase-2--memory-promotion--session-context)
5. [Phase 3 — Pipe-Based Orchestration](#phase-3--pipe-based-orchestration)
6. [Phase 4 — Phoenix Foundation + EventLoop](#phase-4--phoenix-foundation--eventloop)
7. [Phase 4b — User Timezone + User Scoping](#phase-4b--user-timezone--user-scoping)
8. [Phase 4c — Conversation History](#phase-4c--conversation-history)
9. [Phase 4d — Dashboard Refactor (SaladUI + Responsive Layout)](#phase-4d--dashboard-refactor-saladui--responsive-layout)
10. [Phase 5 — Agent Builder + Unified Tool Management](#phase-5--agent-builder--unified-tool-management)
11. [Phase 5b — Chat Orchestrator + REST API Tools + Agent-as-Tool](#phase-5b--chat-orchestrator--rest-api-tools--agent-as-tool)
12. [Phase 5c — Workflow Engine (Static Pipelines)](#phase-5c--workflow-engine-static-pipelines)
13. [Phase 6 — Flow Builder + Triggers](#phase-6--flow-builder--triggers)
14. [Phase 7 — Run View + Memory Inspector](#phase-7--run-view--memory-inspector)
15. [Phase 8 — Hybrid Bridge (Remote Computer Use)](#phase-8--hybrid-bridge-remote-computer-use)
16. [File Manifest](#file-manifest)
17. [Architecture Diagrams](#architecture-diagrams)

---

## Design Philosophy

### Pipes All the Way Down

In Elixir, `|>` transforms data through functions. AgentEx extends this to AI:
tools, agents, and multi-agent teams are all functions — input → transform →
output.

| Level | Transform | Example |
|---|---|---|
| Function | `String.upcase/1` | `data \|> upcase()` |
| Tool | `Tool.execute/2` | `args \|> Pipe.tool(search)` |
| Agent | `ToolCallerLoop.run/5` | `task \|> Pipe.through(researcher)` |
| Fan-out | parallel `ToolCallerLoop` | `task \|> Pipe.fan_out([a, b])` |
| Merge | consolidating agent | `results \|> Pipe.merge(leader)` |

### LLM as Workflow Composer

The LLM doesn't just execute pipe stages — it **reasons about which pattern
to use**. An orchestrator agent receives a task, recalls past workflows from
Tier 3 memory, and dynamically composes the right pipeline.

```elixir
# The orchestrator has sub-agents as tools. It decides the workflow:
orchestrator = Pipe.Agent.new(
  name: "orchestrator",
  system_message: """
  You are a workflow planner. Analyze the task and delegate to the right
  specialists. You can call multiple specialists in parallel if their
  work is independent, or chain them if one depends on another's output.
  """,
  tools: [
    delegate_tool("researcher", researcher),
    delegate_tool("analyst", analyst),
    delegate_tool("writer", writer),
    Memory.save_memory_tool(agent_id: "orchestrator")
  ]
)

# The LLM sees:
# 1. The user's task
# 2. Tier 3 context: "Previously, for stock analysis, I delegated to
#    researcher and analyst in parallel, then writer. This worked well."
# 3. Available tools: delegate_to_researcher, delegate_to_analyst, etc.
#
# It reasons and calls the right tools in the right order.
```

This means the Swarm vs Pipe distinction isn't about **who decides** — the LLM
always decides. The difference is **isolation**:

| Concept | Pipe | Swarm |
|---|---|---|
| Stage boundaries | Clean — each stage gets only previous output | Shared — all agents see full conversation |
| LLM role | Composes workflow via delegate tools | Routes via transfer_to_* tools |
| What changes between stages | The input text | The active agent |
| Best for | Structured transformation pipelines | Dynamic skill-based routing |

Both patterns coexist. Both are LLM-driven.

### Memory-Informed Routing

Tier 3 semantic memory enables smarter workflow decisions:

```text
Session starts
    │
    ├── ContextBuilder.build(agent_id, session_id)
    │     ├── Tier 2: key-value facts (preferences, config)
    │     ├── Tier 3: vector search using last user message
    │     │     → retrieves past session summaries
    │     │     → retrieves saved facts from save_memory tool
    │     │     → retrieves relevant past workflow outcomes
    │     └── Knowledge Graph: entity/relationship context
    │
    ▼
    LLM context window now contains:
    - "Last time for stock analysis, parallel research worked best"
    - "User prefers detailed reports with data tables"
    - "Financial API key stored in vault, not env vars"
    │
    ▼
    LLM makes informed workflow decisions
```

The key: Tier 3 is queried using the **last user message** as a semantic search.
When the user says "Analyze AAPL stock", the search finds past stock analysis
sessions, saved insights about financial tools, and workflow preferences. This
context directly informs the LLM's reasoning about which agents to delegate to
and in what order.

---

## Phase Dependency Graph

```text
Phase 1 (ToolPlugin)  ──────┐
                             ├──▶ Phase 3 (Pipe) ──┐
Phase 2 (Memory Promotion) ─┘                      │
                                                    ▼
Phase 4 (Phoenix + EventLoop) ──▶ Phase 4b (Timezone + Scoping) ──▶ Phase 4c (Conversation History)
                                         │                                    │
                                         ▼                                    ▼
                                  Phase 4d (Dashboard Refactor) ──▶ Phase 5 (Agent Builder + Tools)
                                                                              │
                                                                              ▼
                                                                    Phase 5b (Chat Orchestrator + REST Tools)
                                                                              │
                                                                              ▼
                                                                    Phase 5c (Workflow Engine)
                                                                              │
                                                                              ▼
                                                                    Phase 6 (Flow Builder + Triggers)
                                                                              │
                                                                              ▼
                                                                    Phase 7 (Run View + Memory Inspector)
                                                                              │
                                                                              ▼
                                                                    Phase 8 (Hybrid Bridge — Remote Computer Use)
```

- Phases 1, 2, and 4 can start in **parallel**.
- Phase 3 depends on Phase 1 (plugin integration) and Phase 2 (save_memory tool).
- Phase 4b depends on Phase 4 (auth + Phoenix infrastructure).
- Phase 4c depends on Phase 4b (user-scoped agent_id + Postgres).
- Phase 4d depends on Phase 4b (Phoenix infrastructure). Can run in **parallel** with Phase 4c.
- Phase 5 depends on Phase 4c + Phase 4d (SaladUI components needed for builder UI) + Phase 3.
- Phase 5b depends on Phase 5 (AgentStore) + Phase 3 (Pipe.delegate_tool, Swarm).
- Phase 5c depends on Phase 5b (HttpTool, ToolAssembler) for tool sources in workflow nodes.
- Phase 6 depends on Phase 5c (workflow execution model) + Phase 3 (Pipe/Swarm composition).
  - Phase 6 cron triggers use user timezone for schedule interpretation.
- Phase 7 depends on Phase 6 (execution model) but can start in parallel for memory parts.
- Phase 8 depends on Phase 7 (full platform) + Phase 5 (AgentStore, sandbox config).
  - Phase 8 uses the MCP transport layer (Phase 1 MCP.Client) as the bridge protocol.
  - Phase 8 WebSocket transport leverages Phoenix Channels (Phase 4).

**Recommended order:** 1+2 (parallel) → 3 → 4 → 4b → 4d → 4c → 5 → 5b → 5c → 6 → 7 → 8.

---

## Phase 1 — ToolPlugin Behaviour + Plugin Registry

### Problem

No standard contract for reusable, configurable, lifecycle-managed tool bundles.

### Solution

A behaviour (`AgentEx.ToolPlugin`) + registry (`AgentEx.PluginRegistry`) that
manages plugin lifecycle and delegates tool storage to `Workbench`.

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Plugin is a behaviour, not a GenServer | Simple plugins stay simple. Stateful ones declare child_spec. |
| D2 | Tool names prefixed: `"filesystem.read_file"` | Avoids collisions. Dot valid across all LLM providers. |
| D3 | Config validation reuses `ToolBuilder.params_to_schema/1` | One DSL for tool params and plugin config. |
| D4 | PluginRegistry delegates tool storage to Workbench | No duplication of tool management logic. |
| D5 | `cleanup/1` optional via `@optional_callbacks` | Most plugins are stateless. |

### ToolPlugin Behaviour

```elixir
defmodule AgentEx.ToolPlugin do
  @type manifest :: %{
    name: String.t(),
    version: String.t(),
    description: String.t(),
    config_schema: [AgentEx.ToolBuilder.param_spec()]
  }

  @type init_result ::
    {:ok, [AgentEx.Tool.t()]}
    | {:stateful, [AgentEx.Tool.t()], Supervisor.child_spec()}
    | {:error, term()}

  @callback manifest() :: manifest()
  @callback init(config :: map()) :: init_result()
  @callback cleanup(state :: term()) :: :ok
  @optional_callbacks [cleanup: 1]
end
```

### PluginRegistry API

```elixir
defmodule AgentEx.PluginRegistry do
  start_link(opts)             # opts: [workbench: pid, name: term()]
  attach(registry, module, config \\ %{})   :: :ok | {:error, term()}
  detach(registry, plugin_name)             :: :ok | {:error, :not_attached}
  list_attached(registry)                   :: [PluginInfo.t()]
  get_plugin(registry, plugin_name)         :: {:ok, PluginInfo.t()} | :not_found
end
```

### Example Plugin

```elixir
defmodule AgentEx.Plugins.FileSystem do
  @behaviour AgentEx.ToolPlugin

  @impl true
  def manifest do
    %{
      name: "filesystem", version: "1.0.0",
      description: "Sandboxed file operations",
      config_schema: [
        {:root_path, :string, "Root directory"},
        {:allow_write, :boolean, "Enable writes", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    root = Map.fetch!(config, "root_path")
    allow_write = Map.get(config, "allow_write", false)
    tools = [read_file_tool(root), list_dir_tool(root)]
    tools = if allow_write, do: tools ++ [write_file_tool(root)], else: tools
    {:ok, tools}
  end
end
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/tool_plugin.ex` | Behaviour definition |
| Create | `lib/agent_ex/plugin_registry.ex` | Lifecycle manager GenServer |
| Create | `lib/agent_ex/plugins/file_system.ex` | Built-in file system plugin |
| Create | `lib/agent_ex/plugins/shell_exec.ex` | Built-in shell execution plugin |
| Create | `test/plugin_registry_test.exs` | Registry lifecycle tests |
| Create | `test/plugins/file_system_test.exs` | Plugin tests |
| Modify | `lib/agent_ex/application.ex` | Add `{DynamicSupervisor, name: AgentEx.PluginSupervisor}` |
| Modify | `lib/agent_ex/workbench.ex` | Add `add_tools/2`, `remove_tools/2` batch ops |

**Dependencies:** None.

---

## Phase 2 — Memory Promotion + Session Context

### Problem

Tier 1 is ephemeral — lost on session end. Tier 3 has no automatic connection
to Tier 1. Valuable conversations vanish. Without Tier 3 content, new sessions
start with no long-term context.

### Solution

Two promotion mechanisms that populate Tier 3, which then automatically informs
future sessions via `ContextBuilder`:

```text
Session N:
  Agent works → saves facts (save_memory tool) → Tier 3
  Session closes → LLM summarizes → summary stored in Tier 3

Session N+1:
  Session starts → ContextBuilder queries Tier 3
  → "## Relevant Past Context"
  → LLM sees past facts + summaries in its context window
  → makes better decisions informed by history
```

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D6 | LLM summarization on session close | Filters noise — 50 messages become key facts. |
| D7 | `save_memory` as tool factory | No Phase 1 dependency. Agent calls it mid-conversation. |
| D8 | No automatic/heuristic promotion | Can't distinguish value from noise without LLM judgment. |

### API

```elixir
defmodule AgentEx.Memory.Promotion do
  @doc """
  Close a session and promote a summary to Tier 3.
  1. Retrieves all Tier 1 messages
  2. LLM summarizes into key facts
  3. Stores summary in Tier 3 (embedded as vector)
  4. Stops the Tier 1 session
  """
  @spec close_session_with_summary(String.t(), String.t(), ModelClient.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def close_session_with_summary(agent_id, session_id, model_client, opts \\ [])

  @doc """
  Build a save_memory tool. When the LLM calls it, the fact is embedded
  and stored in Tier 3 for retrieval in future sessions.
  """
  @spec save_memory_tool(keyword()) :: AgentEx.Tool.t()
  def save_memory_tool(opts)   # opts: [agent_id: String.t()]
end
```

### How Tier 3 Context Injection Works

This is the existing `ContextBuilder` flow — no changes needed, but important
to understand how promotion feeds back into future sessions:

```elixir
# In ToolCallerLoop.run/5 (line 77):
input_messages = maybe_inject_memory_context(input_messages, memory_opts)

# This calls Memory.inject_memory_context/3 which calls ContextBuilder.build/3
# which fires 4 parallel tasks:
#
# Task 1: gather_persistent(agent_id)     → Tier 2 key-value facts
# Task 2: gather_knowledge_graph(query)   → KG entity context
# Task 3: gather_semantic(agent_id, query) → Tier 3 vector search ← OUR PROMOTED DATA
# Task 4: gather_conversation(session_id)  → Tier 1 current conversation
#
# The `query` is the last user message content.
# Tier 3 search embeds this query and finds similar past content:
#   - Session summaries from close_session_with_summary
#   - Individual facts from save_memory tool
#
# These become a system message: "## Relevant Past Context\n- fact 1\n- fact 2..."
# injected BEFORE the first LLM call in the new session.
```

**The cycle:**
1. Agent saves facts during session (save_memory tool → Tier 3)
2. Session closes with summary (close_session_with_summary → Tier 3)
3. Next session starts → ContextBuilder queries Tier 3 → finds those facts
4. LLM sees past context → makes informed decisions → saves new facts
5. Repeat — long-term memory accumulates

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/memory/promotion.ex` | Summary + save_memory tool |
| Create | `test/memory/promotion_test.exs` | Tests with mocked ModelClient |
| Modify | `lib/agent_ex/memory.ex` | Facade: `close_session_with_summary/4`, `save_memory_tool/1` |

**Dependencies:** None.

---

## Phase 3 — Pipe-Based Orchestration

### Problem

No composable way to build agent pipelines. The existing Swarm shares one
conversation across agents. No structured transformation pattern where each
stage gets clean input and produces clean output.

### Solution

`AgentEx.Pipe` — function composition for AI. Tools, agents, and teams are
composable transforms. The LLM can both execute within pipe stages AND compose
workflows dynamically.

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D9 | Pipe functions pass strings between stages | Strings are universal between LLM agents. |
| D10 | `through/4` runs a full isolated ToolCallerLoop | Clean boundaries. Each stage has its own conversation. |
| D11 | `fan_out/4` uses `Task.async_stream` | Natural BEAM parallelism. |
| D12 | `merge/4` formats results as structured input | Consolidating agent sees clear per-source results. |
| D13 | `tool/2` enables tool-level chaining in same pipe | Tools and agents participate equally. |
| D14 | Swarm unchanged — different pattern | Pipe = structural isolation. Swarm = shared conversation. Both LLM-driven. |
| D15 | LLM composes pipes via delegate tools | An orchestrator with delegate tools IS dynamic pipe composition. |

### AgentEx.Pipe API

```elixir
defmodule AgentEx.Pipe do
  defmodule Agent do
    @enforce_keys [:name, :system_message]
    defstruct [
      :name, :system_message,
      tools: [], plugins: [], intervention: [],
      max_iterations: 10
    ]
    def new(opts), do: struct!(__MODULE__, opts)
  end

  @doc "Pass input through an agent. Returns agent's text response."
  @spec through(String.t(), Agent.t(), ModelClient.t(), keyword()) :: String.t()
  def through(input, agent, model_client, opts \\ [])

  @doc "Pass input through a tool. Returns tool's output as string."
  @spec tool(String.t() | map(), Tool.t()) :: String.t()
  def tool(input, tool)

  @doc "Fan out input to multiple agents in parallel. Returns list of results."
  @spec fan_out(String.t(), [Agent.t()], ModelClient.t(), keyword()) :: [String.t()]
  def fan_out(input, agents, model_client, opts \\ [])

  @doc "Merge results through a consolidating agent. Returns unified response."
  @spec merge([String.t()], Agent.t(), ModelClient.t(), keyword()) :: String.t()
  def merge(results, consolidator, model_client, opts \\ [])

  @doc "Route input through an LLM or function that selects the next agent."
  @spec route(String.t(), (String.t() -> Agent.t()), ModelClient.t(), keyword()) :: String.t()
  def route(input, router_fn, model_client, opts \\ [])

  @doc "Build a delegate tool — wraps a sub-agent as a tool for orchestrator agents."
  @spec delegate_tool(String.t(), Agent.t(), ModelClient.t(), keyword()) :: Tool.t()
  def delegate_tool(name, agent, model_client, opts \\ [])
end
```

### Three Usage Patterns

#### Pattern 1: Developer-Defined Pipeline (Static)

The developer defines the flow with `|>`. Each stage's output feeds the next:

```elixir
"Analyze AAPL stock"
|> Pipe.through(researcher, client)    # research
|> Pipe.through(analyst, client)       # analyze
|> Pipe.through(writer, client)        # write report
```

#### Pattern 2: LLM-Composed Pipeline (Dynamic)

An orchestrator agent has sub-agents as delegate tools. It decides the workflow
at runtime, informed by Tier 3 memory:

```elixir
orchestrator = Pipe.Agent.new(
  name: "orchestrator",
  system_message: """
  You are a workflow planner. Analyze the task and delegate to specialists.
  Call multiple delegates in parallel if their work is independent.
  Use save_memory to remember what workflows work well.
  """,
  tools: [
    Pipe.delegate_tool("researcher", researcher, client),
    Pipe.delegate_tool("analyst", analyst, client),
    Pipe.delegate_tool("writer", writer, client),
    Memory.save_memory_tool(agent_id: "orchestrator")
  ]
)

# The orchestrator receives the task and decides:
# - "I need research first" → calls delegate_to_researcher
# - "Now analysis" → calls delegate_to_analyst
# - "Let me also call researcher and analyst in parallel" → calls both in one response
# - "Time to write" → calls delegate_to_writer
#
# Tier 3 memory injects: "Last time for stock analysis, I delegated to
# researcher and analyst in parallel, then writer. This produced a good report."
# → The LLM learns from past workflow choices.

"Analyze AAPL stock"
|> Pipe.through(orchestrator, client, memory: %{session_id: "aapl-q1"})
```

When the orchestrator calls multiple delegate tools in one LLM response,
`Sensing.dispatch/3` runs them in parallel via `Task.async_stream`. The LLM
implicitly creates a fan-out pattern by requesting multiple tools at once.

#### Pattern 3: Structural Fan-out + Merge (Hierarchy)

Developer defines parallel execution + consolidation explicitly:

```elixir
"Research Elixir OTP patterns"
|> Pipe.fan_out([web_researcher, code_reader], client)
|> Pipe.merge(lead_researcher, client)
```

### How `delegate_tool/4` Works

This is the bridge between LLM-composed workflows and pipe execution:

```elixir
def delegate_tool(name, %Agent{} = agent, model_client, opts \\ []) do
  Tool.new(
    name: "delegate_to_#{name}",
    description: "Delegate a task to #{name}. #{agent.system_message}",
    kind: :write,
    parameters: %{
      "type" => "object",
      "properties" => %{
        "task" => %{"type" => "string", "description" => "Task for #{name}"}
      },
      "required" => ["task"]
    },
    function: fn %{"task" => task} ->
      # This IS Pipe.through — each delegation runs an isolated ToolCallerLoop
      result = through(task, agent, model_client, opts)
      {:ok, result}
    end
  )
end
```

When the LLM calls `delegate_to_researcher("find AAPL data")`, it runs a full
isolated `ToolCallerLoop` for the researcher agent and returns the result. The
orchestrator LLM sees the result as a tool response and continues reasoning.

### Memory Integration in Pipes

Each pipe stage can have its own memory scope:

```elixir
def through(input, %Agent{} = agent, model_client, opts \\ []) do
  memory = case opts[:memory] do
    %{session_id: sid} -> %{agent_id: agent.name, session_id: sid}
    nil -> nil
  end

  # ... ToolCallerLoop.run with memory: memory
end
```

Memory flow across a pipeline:

```text
Session start → ContextBuilder queries Tier 3
                → "Relevant Past Context" injected as system messages

Each agent stage:
  1. ContextBuilder injects Tier 3 context (past facts + summaries)
  2. Agent runs with tools (including save_memory)
  3. Agent may save new facts to Tier 3 during execution
  4. Agent's conversation stored in Tier 1

Session close → close_session_with_summary → Tier 3

Next session:
  → ContextBuilder finds all saved facts and summaries
  → LLM makes better workflow decisions
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/pipe.ex` | `Pipe.Agent`, `through/4`, `fan_out/4`, `merge/4`, `tool/2`, `route/4`, `delegate_tool/4` |
| Create | `test/pipe_test.exs` | Pipe tests with mock model functions |

**Modify:** None — built on existing primitives.

**Dependencies:** None.

---

## Phase 4 — Phoenix Foundation + EventLoop

### Problem

`ToolCallerLoop.run/5` is synchronous/blocking. No web infrastructure exists.

### Solution

Phoenix LiveView + `EventLoop` wrapper that broadcasts events via PubSub.

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D16 | Single app at `lib/agent_ex_web/` | Standard Phoenix, no umbrella. |
| D17 | Bandit, Tailwind, no JS framework | Lightweight, BEAM-native. |
| D18 | PubSub bridges loops to LiveView | Survives reconnections. |
| D19 | EventLoop uses intervention pipeline | BroadcastHandler broadcasts without blocking. |
| D20 | `model_fn` option added to ToolCallerLoop | Enables think events (Swarm already has this). |
| D21 | ETS RunRegistry for reconnection | Replays events on LiveView reconnect. |

### EventLoop

```elixir
defmodule AgentEx.EventLoop do
  @spec run(String.t(), GenServer.server(), ModelClient.t(), [Message.t()], [Tool.t()], keyword()) ::
          {:ok, String.t()}
  def run(run_id, tool_agent, model_client, messages, tools, opts \\ [])

  @spec subscribe(String.t()) :: :ok
  def subscribe(run_id)

  @spec cancel(String.t()) :: :ok
  def cancel(run_id)
end
```

### Event Types

```elixir
:think_start, :think_complete      # LLM is reasoning
:tool_call, :tool_result           # tool execution
:stage_start, :stage_complete      # pipe stage transitions
:fan_out_start, :fan_out_complete  # parallel execution
:pipeline_complete, :pipeline_error # final result
```

### Pipe EventLoop

Each `Pipe.through/4` and `Pipe.fan_out/4` broadcasts stage events so the UI
can show pipeline progress in real-time:

```text
Pipeline: planner → [researcher, analyst] → writer
            │              │        │           │
UI shows:   ●──────────────●────────●───────────●
         stage_start   fan_out   fan_out    stage_start
                       _start   _complete   (writer)
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex_web.ex` | Web module macros |
| Create | `lib/agent_ex_web/endpoint.ex` | Phoenix.Endpoint |
| Create | `lib/agent_ex_web/router.ex` | Routes |
| Create | `lib/agent_ex_web/telemetry.ex` | Telemetry supervisor |
| Create | `lib/agent_ex_web/components/layouts.ex` | Layout module |
| Create | `lib/agent_ex_web/components/layouts/root.html.heex` | Root HTML |
| Create | `lib/agent_ex_web/components/layouts/app.html.heex` | App layout with sidebar |
| Create | `lib/agent_ex_web/components/core_components.ex` | Buttons, inputs, modals |
| Create | `lib/agent_ex_web/live/chat_live.ex` | Chat interface |
| Create | `lib/agent_ex_web/live/chat_live.html.heex` | Chat template |
| Create | `lib/agent_ex_web/components/chat_components.ex` | Message bubble, tool card |
| Create | `lib/agent_ex/event_loop/event_loop.ex` | Async wrapper |
| Create | `lib/agent_ex/event_loop/event.ex` | Event types |
| Create | `lib/agent_ex/event_loop/broadcast_handler.ex` | Intervention broadcaster |
| Create | `lib/agent_ex/event_loop/run_registry.ex` | ETS active run tracking |
| Create | `lib/agent_ex/event_loop/pipe_runner.ex` | Pipe event broadcasting |
| Create | `assets/js/app.js` | LiveView client + hooks |
| Create | `assets/css/app.css` | Tailwind directives |
| Create | `assets/tailwind.config.js` | Tailwind config |
| Modify | `mix.exs` | Add Phoenix deps |
| Modify | `lib/agent_ex/application.ex` | Add PubSub, TaskSupervisor, Endpoint |
| Modify | `lib/agent_ex/tool_caller_loop.ex` | Add `:model_fn` option |
| Modify | `config/config.exs` | Endpoint, esbuild, tailwind |
| Modify | `config/dev.exs` | Dev server, watchers |
| Modify | `config/runtime.exs` | PHX_HOST, PHX_PORT |
| Modify | `.gitignore` | Static assets |

**New dependencies:**

```elixir
{:phoenix, "~> 1.7"}, {:phoenix_html, "~> 4.2"}, {:phoenix_live_view, "~> 1.0"},
{:phoenix_live_reload, "~> 1.5", only: :dev}, {:bandit, "~> 1.6"},
{:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
{:esbuild, "~> 0.9", runtime: Mix.env() == :dev}
```

---

## Phase 4b — User Timezone + User Scoping

### Problem (Timezone)

All timestamps in the system are UTC-only. When Phase 6 introduces scheduled
triggers (cron), `0 9 * * *` has no meaning without knowing the user's timezone.
Run history, memory timestamps, and any time-aware agent output also need
correct local time. Without timezone support at the user level, every downstream
feature that touches time will need ad-hoc workarounds.

### Problem (User Scoping)

Phases 1–4 have **zero user awareness**. The critical gap: ChatLive hardcodes
`@agent_id "chat"` — all users share the same memory space (Tier 1, 2, and 3).
RunRegistry stores runs without user ownership. Phase 5 introduces per-user
agent configs and cannot work without user-scoped identifiers.

**Current scoping audit:**

| Module | Scoped By | User-Aware? |
|---|---|---|
| Phase 1 — Plugins, PluginRegistry | Global (system-level) | No — correct, stays global |
| Phase 2 — Memory (all 3 tiers) | `agent_id` only | No — needs user-scoped agent_ids |
| Phase 3 — Pipe | Stateless | N/A — no change needed |
| Phase 4 — EventLoop, RunRegistry | `run_id` only | No — needs `user_id` in metadata |
| Phase 4 — ChatLive | Hardcoded `@agent_id "chat"` | Has `current_scope.user` but **ignores it** |

The architecture already has the right isolation boundary (`agent_id`). The core
modules don't need structural changes — what's missing is **wiring `user_id`
into ID generation** at the LiveView layer.

### Solution (Timezone)

Add a `timezone` field (IANA string, e.g. `"Asia/Jakarta"`) to the User schema,
collected at registration and changeable in settings. Provide a helper module
(`AgentEx.Timezone`) for converting UTC timestamps to user-local time. Use the
`tz` library as the timezone database for Elixir's `Calendar` system — it's
lighter than `tzdata` and uses OS-provided timezone data.

### Solution (User Scoping)

Wire `user.id` into agent_id generation and run metadata. No deep refactor of
Phases 1–4 internals — just fix how IDs are constructed at the boundary.

**Scoping strategy:**

```elixir
# Before (ChatLive) — all users share memory:
@agent_id "chat"
Memory.start_session(@agent_id, session_id)

# After — per-user isolation:
agent_id = "user_#{user.id}_chat"
Memory.start_session(agent_id, session_id)
```

```elixir
# Before (EventLoop) — no user ownership:
EventLoop.run(run_id, tool_agent, client, messages, tools, memory: memory_opts)

# After — user_id in metadata for filtering:
EventLoop.run(run_id, tool_agent, client, messages, tools,
  memory: memory_opts,
  metadata: %{user_id: user.id}
)
```

**What changes and what doesn't:**

| Module | Change? | Detail |
|---|---|---|
| Phase 1 — ToolPlugin, PluginRegistry | No | System-level infrastructure, correctly global |
| Phase 1 — FileSystem, ShellExec plugins | No | Sandbox via config, not user identity |
| Phase 2 — Memory (all tiers) | No internal change | Already scoped by `agent_id` — just receives user-scoped IDs |
| Phase 2 — ContextBuilder | No internal change | Accepts `agent_id`, works as-is |
| Phase 3 — Pipe | No | Stateless, passes through whatever `agent_id` it receives |
| Phase 4 — EventLoop | Minor | Pass `metadata: %{user_id: ...}` to `RunRegistry.register_run/2` |
| Phase 4 — RunRegistry | No internal change | Already accepts `metadata` map — just receives `user_id` now |
| Phase 4 — ChatLive | **Yes** | Derive `agent_id` from `current_scope.user.id`, pass `user_id` in run metadata |
| Phase 4 — BroadcastHandler | No | Broadcasts by `run_id`, unaffected |

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D22 | IANA timezone strings (e.g. `"Asia/Jakarta"`) | Industry standard, unambiguous, supported by `Calendar`. |
| D23 | `tz` hex package, not `tzdata` | Lighter footprint, uses OS tz data, no bundled DB to update. |
| D24 | Default to `"Etc/UTC"` if not set | Safe fallback — never crash on missing timezone. |
| D25 | Timezone select grouped by region | Better UX than a flat 400-item dropdown. |
| D26 | Collect at registration, editable in settings | One-time setup with escape hatch. User picks once. |
| D27 | `AgentEx.Timezone` helper module | Single place for UTC→local conversion used by EventLoop, RunRegistry, memory timestamps, and Phase 6 triggers. |
| D28 | `agent_id = "user_#{user.id}_chat"` pattern | Scopes memory per-user without changing Memory internals. Phase 5 replaces `_chat` with agent config names. |
| D29 | `user_id` in RunRegistry metadata, not struct | No schema change to RunRegistry — metadata map is already there and accepted. |
| D30 | Plugins stay global (no user scoping) | Plugins are system infrastructure. Per-user tool selection happens in Phase 5 via agent configs. |
| D31 | No enforcement layer yet | Phase 5 agent configs will own the user→agent mapping. Phase 4b just wires in the IDs. Adding authorization checks before the data model exists would be premature. |

### User Schema Change

```elixir
# Add to users table
field(:timezone, :string, default: "Etc/UTC")
```

### Timezone Helper

```elixir
defmodule AgentEx.Timezone do
  @default_timezone "Etc/UTC"

  @doc "Convert a UTC DateTime to the user's local timezone."
  @spec to_local(DateTime.t(), String.t() | nil) :: DateTime.t()
  def to_local(utc_datetime, timezone)

  @doc "List all IANA timezones grouped by region."
  @spec grouped_timezones() :: [{String.t(), [String.t()]}]
  def grouped_timezones()

  @doc "Validate that a timezone string is a known IANA timezone."
  @spec valid?(String.t()) :: boolean()
  def valid?(timezone)

  @doc "Get display label for a timezone (e.g. 'Asia/Jakarta (UTC+7)')."
  @spec label(String.t()) :: String.t()
  def label(timezone)
end
```

### Registration Flow

```text
Registration form (current):     Registration form (updated):
┌──────────────────────────┐     ┌──────────────────────────┐
│ Username: [____________] │     │ Username: [____________] │
│ Email:    [____________] │     │ Email:    [____________] │
│ Password: [____________] │     │ Password: [____________] │
│                          │     │ Timezone: [Asia/Jakarta▼]│
│ [Sign up →]              │     │                          │
└──────────────────────────┘     │ [Sign up →]              │
                                 └──────────────────────────┘
```

The timezone select is auto-detected via the browser's
`Intl.DateTimeFormat().resolvedOptions().timeZone` on mount, so most users
won't need to touch it.

### ChatLive User Scoping

```text
Before:                              After:
┌──────────────────────────────┐     ┌──────────────────────────────┐
│ ChatLive                     │     │ ChatLive                     │
│                              │     │                              │
│ @agent_id "chat"  ← global   │     │ agent_id = fn user ->        │
│                              │     │   "user_#{user.id}_chat"     │
│ Memory.start_session(        │     │ end                          │
│   "chat", session_id)        │     │                              │
│                              │     │ Memory.start_session(        │
│ EventLoop.run(run_id, ...)   │     │   agent_id, session_id)      │
│   # no user tracking         │     │                              │
│                              │     │ EventLoop.run(run_id, ...,   │
│                              │     │   metadata: %{               │
│                              │     │     user_id: user.id          │
│                              │     │   })                         │
└──────────────────────────────┘     └──────────────────────────────┘

Memory isolation:                    Memory isolation:
User A → agent_id "chat"            User A → agent_id "user_1_chat"
User B → agent_id "chat"  ← SHARED  User B → agent_id "user_2_chat"  ← ISOLATED
```

### Downstream Usage (future phases)

| Consumer | How timezone is used |
|---|---|
| Phase 5 — Agent Builder | Display agent creation timestamps in local time |
| Phase 6 — Cron Triggers | Interpret cron schedule in user's timezone |
| Phase 6 — Run History | Show "completed at 2:30 PM" in local time |
| Phase 7 — Memory Inspector | Display memory entry timestamps locally |
| EventLoop events | Timestamp events in local time for UI display |

| Consumer | How user scoping is used |
|---|---|
| Phase 5 — Agent Builder | Agent configs belong to `user_id`, `agent_id` = `"user_#{id}_#{name}"` |
| Phase 5 — Unified Tools | Tool selection per agent per user |
| Phase 6 — Run History | Filter runs by `user_id` from RunRegistry metadata |
| Phase 6 — Triggers | Triggers owned by user, fire with user context |
| Phase 7 — Memory Inspector | Show only current user's agent memories |

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/timezone.ex` | Timezone helper (conversion, validation, listing) |
| Create | `priv/repo/migrations/*_add_timezone_to_users.exs` | Add `timezone` column |
| Create | `assets/js/hooks/timezone_detect.js` | JS hook to detect browser timezone on mount |
| Modify | `lib/agent_ex/accounts/user.ex` | Add `:timezone` field + `timezone_changeset/3` |
| Modify | `lib/agent_ex/accounts.ex` | Add `change_user_timezone/3`, `update_user_timezone/2` |
| Modify | `lib/agent_ex_web/live/user_live/registration.ex` | Add timezone select with browser auto-detect |
| Modify | `lib/agent_ex_web/live/user_live/settings.ex` | Add timezone section |
| Modify | `lib/agent_ex_web/live/chat_live.ex` | Derive `agent_id` from user, pass `user_id` in run metadata |
| Modify | `mix.exs` | Add `{:tz, "~> 0.28"}` |
| Modify | `config/config.exs` | Set `config :elixir, :time_zone_database, Tz.TimeZoneDatabase` |
| Modify | `assets/js/app.js` | Register TimezoneDetect hook |

**New dependency:**

```elixir
{:tz, "~> 0.28"}
```

---

## Phase 4c — Conversation History

### Problem

Tier 1 Working Memory (GenServer state) is ephemeral — messages vanish when the
user logs out, the session cookie is cleared, or the BEAM restarts. On re-login,
`ensure_chat_session` generates a new random session ID, making old Working
Memory unreachable. Users lose all conversation history between sessions.

**Current data flow (broken):**

```text
User chats → messages stored in WorkingMemory.Server (GenServer RAM)
User logs out → clear_session() destroys chat_session_id cookie
User logs in → new session_id generated → old messages unreachable
```

Meanwhile, the 3-tier memory system works correctly for LLM context (Tier 2
facts, Tier 3 semantic search, Knowledge Graph) — but the raw conversation
history that the **UI** needs to display is not persisted anywhere.

### Solution

Store conversation history in Postgres. This is a **display layer** — the
persistent record of what was said. It does not replace any memory tier:

```text
┌─────────────────────────────────────────────────────────────────┐
│                     What each layer does                         │
├─────────────────────────────────────────────────────────────────┤
│ Postgres conversations/messages  → UI display + resume history  │
│ Tier 1 Working Memory (GenServer)→ Active session context cache │
│ Tier 2 Persistent Memory (ETS)   → Key-value facts per agent   │
│ Tier 3 Semantic Memory (HelixDB) → Vector search for LLM context│
│ Knowledge Graph (HelixDB)        → Entity/relationship context  │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** ContextBuilder already has a 4000-token budget for conversation
with most-recent-first truncation (`truncate_conversation/2`). When resuming a
conversation, we load messages from Postgres into Working Memory. The existing
budget system prevents context flooding — only the tail end enters the LLM
context window, regardless of conversation length.

**Resumable conversations come for free:** hydrate Tier 1 from Postgres on
resume, and ContextBuilder's truncation handles the rest. No architecture change
to the memory system.

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D32 | Postgres for history, not DETS/ETS | Conversations are relational data (user → conversations → messages). Postgres gives querying, pagination, and survives deploys. Already in the stack via Ecto. |
| D33 | Conversations scoped to `user_id`, not `agent_id` | Phase 5 will allow multiple agents per user. A conversation belongs to the user; the agent used is metadata on the conversation. |
| D34 | Stable conversation ID replaces random `chat_session_id` | Use the Postgres conversation UUID as the session identifier. No more volatile session cookie IDs. |
| D35 | Messages saved inline during chat (not on session close) | Messages are written to Postgres as they occur, so nothing is lost if the browser tab closes or the server crashes. |
| D36 | Resume hydrates Tier 1 from Postgres | On conversation resume, load last N messages from DB into WorkingMemory.Server. ContextBuilder's 4000-token budget prevents flooding. |
| D37 | Conversation list in sidebar | Users need to browse/switch conversations. Sidebar shows recent conversations with titles. |
| D38 | Auto-title from first user message | LLM-generated titles are expensive and slow. Use first ~50 chars of first user message as title, with option to rename later. |

### Schema

```elixir
# conversations table
schema "conversations" do
  belongs_to :user, AgentEx.Accounts.User
  field :title, :string                    # auto-generated from first message
  field :model, :string                    # e.g. "gpt-4o-mini"
  field :provider, :string                 # e.g. "openai"
  timestamps(type: :utc_datetime_usec)
end

# conversation_messages table
schema "conversation_messages" do
  belongs_to :conversation, AgentEx.Chat.Conversation
  field :role, :string                     # "user", "assistant", "system"
  field :content, :text
  timestamps(type: :utc_datetime_usec, updated_at: false)
end
```

### Flow

```text
New conversation:
  User opens chat → create Conversation row → use conversation.id as session_id
  → start WorkingMemory.Server(agent_id, conversation.id)
  → each message saved to both WorkingMemory + Postgres

Resume conversation:
  User picks from sidebar → load Conversation + last N messages from Postgres
  → hydrate WorkingMemory.Server with loaded messages
  → ContextBuilder picks up Tier 1 as normal (budget-truncated)
  → user continues chatting, new messages saved to both stores

Logout / reconnect:
  WorkingMemory.Server may die (ephemeral, that's fine)
  Postgres has the full record
  On resume → hydrate again from Postgres
```

### ChatLive Changes

```text
Before:                              After:
┌──────────────────────────────┐     ┌──────────────────────────────┐
│ ChatLive                     │     │ ChatLive                     │
│                              │     │                              │
│ session_id from cookie       │     │ conversation_id from DB      │
│   (volatile, random)         │     │   (stable, Postgres UUID)    │
│                              │     │                              │
│ Messages in GenServer only   │     │ Messages in GenServer + DB   │
│   (lost on logout)           │     │   (DB is source of truth)    │
│                              │     │                              │
│ No conversation list         │     │ Sidebar: recent conversations│
│ No resume capability         │     │ Click to resume any convo    │
│                              │     │                              │
│ restore_messages reads       │     │ restore_messages reads       │
│   from WorkingMemory         │     │   from Postgres (hydrates WM)│
└──────────────────────────────┘     └──────────────────────────────┘
```

### Sidebar UI

```text
┌──────────────┬──────────────────────────────────────────────┐
│ Conversations│  Chat Area                                    │
│              │                                               │
│ + New Chat   │  ● User: Analyze AAPL stock                  │
│              │  ● Assistant: AAPL is currently...            │
│ Today        │                                               │
│ ▸ Analyze AAP│  ● User: What about earnings?                │
│ ▸ Fix login b│  ● Assistant: The Q4 earnings...             │
│              │                                               │
│ Yesterday    │                                               │
│ ▸ Deploy plan│  [Type a message...              ] [Send]    │
│ ▸ OTP supervi│                                               │
└──────────────┴──────────────────────────────────────────────┘
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/chat.ex` | Chat context: CRUD for conversations + messages |
| Create | `lib/agent_ex/chat/conversation.ex` | Conversation Ecto schema |
| Create | `lib/agent_ex/chat/message.ex` | ConversationMessage Ecto schema |
| Create | `priv/repo/migrations/*_create_conversations.exs` | conversations + conversation_messages tables |
| Create | `lib/agent_ex_web/components/conversation_components.ex` | Sidebar conversation list, conversation item |
| Create | `test/agent_ex/chat_test.exs` | Chat context tests |
| Modify | `lib/agent_ex_web/live/chat_live.ex` | Use conversation_id instead of session cookie; save to Postgres; sidebar; resume |
| Modify | `lib/agent_ex_web/router.ex` | Remove `ensure_chat_session` plug; add `/chat/:conversation_id` route |
| Modify | `lib/agent_ex_web/components/chat_components.ex` | Add sidebar layout wrapper |

**Dependencies:** Phase 4b (user-scoped agent_id, Postgres/Ecto already configured).

---

## Phase 4d — Dashboard Refactor (SaladUI + Responsive Layout)

### Problem

The dashboard uses hand-rolled Tailwind HTML for all UI — no component library.
The sidebar is fixed-width (`w-56`) with no mobile or tablet support. Every UI
element (buttons, cards, selects, badges) is styled inline with duplicated
Tailwind classes. Phase 5 (Agent Builder) needs a component library foundation
for cards, dialogs, tabs, dropdowns, and drag-and-drop — building on raw HTML
would compound the duplication problem.

### Solution

Install SaladUI (shadcn/ui port for Phoenix LiveView) as the component library
and refactor the existing dashboard to use it. Add responsive 3-breakpoint
sidebar navigation.

**SaladUI components used:**
- `Card` — settings sections, tool cards, future agent cards
- `Badge` — status indicators, model labels
- `Button` — actions (imported locally to avoid CoreComponents conflict)
- `Separator` — section dividers
- `Tooltip` — icon-only sidebar labels on tablet
- `Sheet` — mobile sidebar overlay

**Responsive sidebar:**

```text
Mobile (< 768px)         Tablet (768-1023px)       Desktop (≥ 1024px)
┌──────────────────┐     ┌────┬─────────────┐     ┌─────────┬──────────────┐
│  ☰  AgentEx      │     │ 💬 │             │     │ 💬 Chat  │              │
├──────────────────┤     │ ⚙  │   Content    │     │ ⚙ Settin│   Content    │
│                  │     │ 👤 │   area       │     │ 👤 Profi │   area       │
│  Content area    │     │    │              │     │          │              │
│  (full width)    │     │    │              │     │  v0.1.0  │              │
└──────────────────┘     └────┴─────────────┘     └─────────┴──────────────┘
 Hidden sidebar,          Icon-only rail            Full expanded sidebar
 hamburger toggle          (w-16)                    (w-64)
```

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D39 | SaladUI as component library | shadcn/ui design language, 30+ HEEX components, native dark mode, no Alpine.js dependency. 106K hex downloads. |
| D40 | Do NOT import `SaladUI.Button` globally | Conflicts with `CoreComponents.button/1` which auth pages depend on. Import locally per-module. |
| D41 | Keep native `<select>` for provider/model pickers | SaladUI Select uses JS-driven state that may not emit `phx-change` events. Native selects preserve existing event handlers. |
| D42 | Keep `CoreComponents` for form-aware inputs | `input/1` integrates with `Phoenix.HTML.FormField` (error display, `used_input?` checks). SaladUI does not provide this. |
| D43 | Mobile sidebar via SaladUI `Sheet` | Built-in backdrop, close button, slide animation. Uses `Phoenix.LiveView.JS`, not Alpine.js. |
| D44 | Active link via `@socket.view` module match | Available in layout without extra assigns. Simpler than path-based matching. |

### Files

| Action | File | Purpose |
|---|---|---|
| Modify | `mix.exs` | Add `{:salad_ui, "~> 1.0.0-beta.3"}` |
| Modify | `config/config.exs` | Add `config :salad_ui, color_scheme: :default` |
| Modify | `assets/tailwind.config.js` | darkMode, content path, colors, animate plugin |
| Modify | `assets/js/app.js` | Register SaladUI JS hook |
| Modify | `lib/agent_ex_web.ex` | Add SaladUI imports to `html_helpers/0` |
| Modify | `layouts/root.html.heex` | Add `dark` class to `<html>` |
| Modify | `layouts/auth.html.heex` | Add `dark` class to `<html>` |
| Modify | `layouts/app.html.heex` | Full responsive sidebar rewrite |
| Modify | `live/chat_live.html.heex` | SaladUI buttons, badge, refined empty state |
| Modify | `live/chat_live.ex` | Add local SaladUI.Button/Badge imports |
| Modify | `components/chat_components.ex` | Tool card → SaladUI Card + Badge |
| Modify | `live/user_live/settings.ex` | Card sections → SaladUI Card + Separator |

**New dependency:**

```elixir
{:salad_ui, "~> 1.0.0-beta.3"}
```

**Dependencies:** Phase 4b (Phoenix infrastructure). Can run in parallel with Phase 4c.

---

## Phase 5 — Agent Builder + Unified Tool Management

### Cleanup from Phase 4

Remove demo tool scaffolding once the agent builder UI is in place:

| File | What to remove | Why |
|---|---|---|
| `config/dev.exs` | `chat_tools: :demo` config line | Replaced by per-agent tool selection in UI |
| `lib/agent_ex_web/live/chat_live.ex` | `load_chat_tools/0`, `demo_tools/0` functions | Replaced by agent config |
| `lib/agent_ex_web/live/chat_live.ex` | Change `tools: load_chat_tools()` to agent-supplied tools | Tools come from agent definition |

### Problem

Agents, tools, and intervention pipelines are configured only in code. No way
to create agents, assign tools, connect MCP servers, or manage plugins through
the UI. The current chat view doesn't reflect AgentEx's multi-agent capabilities.

### Solution

**Agent Builder** — create/edit agents with name, system prompt, provider/model,
tool selection, memory config, and intervention rules. Visual agent cards showing
each agent's capabilities at a glance.

**Unified Tool Management** — single panel for all tool sources. Everything
becomes a `Tool` struct regardless of origin:

| Source | Backend | UI Flow |
|---|---|---|
| Local function | `Tool.new(function: fn -> ... end)` | Custom tool form (name, schema, code) |
| Plugin bundle | `ToolPlugin` → `PluginRegistry.attach` | Plugin browser, attach/detach toggle |
| MCP server | `MCP.Client.connect` → `MCP.ToolAdapter.to_agent_tools` | Transport picker (stdio/HTTP), command input, auto-discover |
| REST API | Plugin wrapping `Req` in a `Tool` | Plugin template for HTTP tools |
| Shell commands | `Plugins.ShellExec` with allowlist | Built-in plugin config (allowlist editor) |
| File system | `Plugins.FileSystem` with sandbox | Built-in plugin config (root path, write toggle) |
| Another agent | `Handoff.transfer_tools` | Agent picker in flow builder (Phase 6) |

**Intervention Builder** — drag-and-drop intervention pipeline per agent with
live permission decision matrix.

### Design

```text
┌─────────────────────────────────────────────────────────────┐
│  Agents Tab                                                  │
├─────────────────────────────────────────────────────────────┤
│ + New Agent                                                  │
│ ┌────────────┐ ┌────────────┐ ┌────────────┐               │
│ │ Researcher │ │  Analyst   │ │   Writer   │               │
│ │ gpt-5.4    │ │ claude-h   │ │ claude-h   │               │
│ │ 3 tools    │ │ 2 tools    │ │ 0 tools    │               │
│ │ Tier 2 mem │ │ Tier 3 mem │ │ Tier 1     │               │
│ └────────────┘ └────────────┘ └────────────┘               │
│                                                              │
│ Agent editor: name, system prompt, model, tools,             │
│ memory config, intervention rules                            │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Tools Tab                                                   │
├─────────────────────────────────────────────────────────────┤
│  Built-in     Plugins      MCP Servers     Custom            │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐                     │
│ │ Shell    │ │ GitHub   │ │ MCP:     │                     │
│ │ :write   │ │ :read    │ │ sqlite   │                     │
│ │ allowlist│ │ via MCP  │ │ stdio    │                     │
│ └──────────┘ └──────────┘ └──────────┘                     │
│                                                              │
│ + Attach Plugin  + Connect MCP  + Custom Tool                │
│                                                              │
│ MCP connection form:                                         │
│   Transport: [stdio | http]                                  │
│   Command/URL: npx @anthropic/mcp-server-sqlite             │
│   [Connect] → auto-discovers tools via MCP.ToolAdapter      │
└─────────────────────────────────────────────────────────────┘
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/agent_config.ex` | Agent definition struct (name, prompt, model, tools, memory, intervention) |
| Create | `lib/agent_ex/agent_store.ex` | ETS/DETS persistence for agent configs |
| Create | `lib/agent_ex_web/live/agents_live.ex` | Agent list + builder |
| Create | `lib/agent_ex_web/live/agents_live.html.heex` | Template |
| Create | `lib/agent_ex_web/live/tools_live.ex` | Unified tool manager (plugins, MCP, custom) |
| Create | `lib/agent_ex_web/live/tools_live.html.heex` | Template |
| Create | `lib/agent_ex_web/components/agent_components.ex` | Agent cards, editor forms |
| Create | `lib/agent_ex_web/components/tool_components.ex` | Tool cards, MCP connect form, plugin browser |
| Create | `lib/agent_ex_web/live/intervention_builder_live.ex` | Drag-and-drop pipeline editor |
| Create | `lib/agent_ex_web/live/intervention_builder_live.html.heex` | Template |
| Create | `lib/agent_ex_web/components/intervention_components.ex` | Handler cards, decision matrix |
| Create | `assets/js/hooks/sortable.js` | SortableJS hook for pipeline ordering |
| Modify | `lib/agent_ex_web/router.ex` | Add `/agents`, `/tools`, `/interventions` |
| Modify | `lib/agent_ex_web/components/layouts/app.html.heex` | Tabbed workspace nav |
| Modify | `assets/js/app.js` | Register Sortable hook |
| Modify | `lib/agent_ex_web/live/chat_live.ex` | Load tools from agent config instead of app config |

---

## Phase 5b — Chat Orchestrator + REST API Tools + Agent-as-Tool

### Core Insight

**Every agent is a tool. Every tool source is equal. The LLM reasons about
which pattern to use.** The chat model doesn't just answer questions — it's an
orchestrator that decomposes tasks, delegates to specialist agents, and
composes results. The pattern (sequential, parallel, swarm) emerges from the
LLM's reasoning, not from hardcoded logic.

```text
User: "Research AAPL and write me an investment report"
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  CHAT ORCHESTRATOR (LLM reasoning)                          │
│                                                             │
│  System: "You are a task orchestrator. You have specialist  │
│  agents and tools available. Decompose complex tasks into   │
│  steps. Delegate to the right specialist. For independent   │
│  work, call multiple tools in one turn (parallel). For      │
│  sequential work, chain results from one to the next."      │
│                                                             │
│  Tools (auto-assembled):                                    │
│  ├─ delegate_to_researcher    ← AgentStore → delegate_tool  │
│  ├─ delegate_to_analyst       ← AgentStore → delegate_tool  │
│  ├─ delegate_to_writer        ← AgentStore → delegate_tool  │
│  ├─ stock_api.get_quote       ← REST API tool (HTTP)        │
│  ├─ mcp.sqlite.query          ← MCP server tool             │
│  ├─ filesystem.read_file      ← Plugin tool                 │
│  └─ get_current_time          ← Local function tool         │
└─────────────────────────────────────────────────────────────┘
        │
        ▼ LLM reasons: "I need research first, then analysis, then writing"
        │
        ▼ Step 1: calls delegate_to_researcher("Find recent AAPL news")
        │          └─ Researcher runs its own ToolCallerLoop with its own tools
        │          └─ Returns research summary
        │
        ▼ Step 2: calls delegate_to_analyst(research_summary + "Analyze fundamentals")
        │          └─ Analyst runs with stock_api tools
        │          └─ Returns analysis
        │
        ▼ Step 3: calls delegate_to_writer(analysis + "Write investment report")
        │          └─ Writer runs with no tools (pure LLM)
        │          └─ Returns final report
        │
        ▼ Chat returns report to user
```

### Problem

1. **Chat doesn't use agents** — AgentStore has agent configs but ChatLive still
   uses hardcoded demo tools. No bridge between stored agents and the chat model.

2. **No REST API tools** — MCP and plugins exist, but there's no way to define
   HTTP API tools (like n8n HTTP Request nodes) through the UI. Many real-world
   integrations are simple REST calls.

3. **No orchestration in chat** — the chat model answers directly with its own
   tools. It can't delegate to specialist agents or compose multi-step workflows.

4. **Pattern selection is manual** — Pipe vs Swarm is chosen in code. The LLM
   should reason about which pattern fits the task.

### Solution

Three sub-systems that work together:

#### 5b-A: REST API Tool Builder

Define HTTP tools through a UI form — like n8n's HTTP Request node:

```text
┌─────────────────────────────────────────────────────────────┐
│  New HTTP Tool                                               │
├─────────────────────────────────────────────────────────────┤
│  Name: stock_api.get_quote                                   │
│  Description: Fetch stock quote by ticker symbol             │
│  Kind: [read ▼]                                              │
│                                                              │
│  Method: [GET ▼]                                             │
│  URL Template: https://api.example.com/quote/{{ticker}}      │
│  Headers:                                                    │
│    Authorization: Bearer {{api_key}}                         │
│  Parameters:                                                 │
│    ┌──────────┬──────────┬─────────────┬──────────┐         │
│    │ Name     │ Type     │ Description │ Required │         │
│    ├──────────┼──────────┼─────────────┼──────────┤         │
│    │ ticker   │ string   │ Stock symbol│ yes      │         │
│    └──────────┴──────────┴─────────────┴──────────┘         │
│  Response: [json_body ▼]  JSONPath: $.data                   │
│                                                              │
│  [Test] [Save]                                               │
└─────────────────────────────────────────────────────────────┘
```

Backend: `HttpTool` struct that serializes to/from ETS/DETS and generates a
`Tool.new` with a `Req`-based function at runtime.

```elixir
defmodule AgentEx.HttpTool do
  defstruct [:id, :user_id, :name, :description, :kind,
             :method, :url_template, :headers, :parameters,
             :response_type, :response_path,
             :auth_type, :auth_config,
             :inserted_at, :updated_at]

  def to_tool(%__MODULE__{} = config) do
    Tool.new(
      name: config.name,
      description: config.description,
      kind: config.kind,
      parameters: build_json_schema(config.parameters),
      function: fn args ->
        url = interpolate(config.url_template, args)
        headers = interpolate_headers(config.headers, args)

        case Req.request(method: config.method, url: url, headers: headers) do
          {:ok, %{status: s, body: body}} when s in 200..299 ->
            {:ok, extract_response(body, config.response_path)}
          {:ok, %{status: s, body: body}} ->
            {:error, "HTTP #{s}: #{inspect(body)}"}
          {:error, e} ->
            {:error, inspect(e)}
        end
      end
    )
  end
end
```

#### 5b-B: Agent-as-Tool Bridge

Auto-generates `delegate_to_*` tools from `AgentStore` for the chat orchestrator:

```elixir
defmodule AgentEx.AgentBridge do
  @moduledoc """
  Converts AgentStore configs into delegate tools for the chat orchestrator.
  Each agent becomes a callable tool — the LLM delegates by calling it.
  """

  alias AgentEx.{AgentConfig, AgentStore, Pipe, Tool}

  @doc """
  Build delegate tools for all agents owned by a user.
  Each agent becomes: delegate_to_<name>(task) → runs agent's full loop → returns result.
  """
  def delegate_tools(user_id, model_client, opts \\ []) do
    AgentStore.list(user_id)
    |> Enum.map(fn config -> delegate_tool_from_config(config, model_client, opts) end)
  end

  defp delegate_tool_from_config(%AgentConfig{} = config, model_client, opts) do
    pipe_agent = Pipe.Agent.new(
      name: config.name,
      system_message: config.system_prompt,
      tools: resolve_tools(config, opts),
      intervention: resolve_intervention(config)
    )

    Pipe.delegate_tool(config.name, pipe_agent, model_client,
      memory: %{agent_id: "agent_#{config.id}"}
    )
  end

  defp resolve_tools(%AgentConfig{tool_ids: ids}, opts) do
    # Resolve tool_ids → actual Tool structs from:
    # 1. HttpTool configs (REST API tools)
    # 2. MCP connected tools
    # 3. Plugin tools
    # 4. Built-in tools
    # Phase 5b starts with all available tools; per-agent filtering in future
    Keyword.get(opts, :available_tools, [])
  end

  defp resolve_intervention(%AgentConfig{intervention_pipeline: []}), do: []
  defp resolve_intervention(%AgentConfig{intervention_pipeline: handler_ids}) do
    # Resolve handler IDs to actual intervention handler modules
    Enum.filter_map(handler_ids, fn id ->
      case id do
        "permission_handler" -> AgentEx.Intervention.PermissionHandler
        "write_gate_handler" -> AgentEx.Intervention.WriteGateHandler
        "log_handler" -> AgentEx.Intervention.LogHandler
        _ -> nil
      end
    end)
  end
end
```

#### 5b-C: Chat Orchestrator

Rewires `ChatLive.send_message/3` to assemble **all tool sources** into a unified
tool list, with agents as delegate tools and an orchestrator system prompt:

```text
┌───────────────────────────────────────────────────────┐
│  Tool Assembly (on each message send)                  │
│                                                        │
│  1. Utility tools (get_current_time, etc.)             │
│  2. REST API tools (HttpTool.list → Tool)              │
│  3. MCP tools (connected servers → ToolAdapter)        │
│  4. Plugin tools (attached plugins → tools)            │
│  5. Agent delegate tools (AgentBridge.delegate_tools)  │
│                                                        │
│  ALL → flat [%Tool{}] list → ToolAgent → EventLoop     │
└───────────────────────────────────────────────────────┘
```

The chat model gets an orchestrator system prompt that teaches it to reason:

```elixir
@orchestrator_prompt """
You are an AI assistant with access to specialist agents and tools.

## How to work:
- For simple questions, answer directly using your knowledge.
- For tasks requiring specific tools, use them directly.
- For complex tasks, decompose into steps and delegate to specialist agents.
- When delegating, pass clear task descriptions to each agent.
- Each specialist runs independently with its own tools and returns a result.
- You can call multiple agents in one turn if their work is independent.

## Available specialists:
{{agent_descriptions}}

## Pattern selection:
- **Direct**: Simple questions → answer without tools
- **Tool use**: Specific data needed → call the relevant tool
- **Sequential delegation**: Task A's output feeds Task B → delegate one at a time
- **Parallel delegation**: Independent subtasks → call multiple delegates in one turn
- **Conversation**: Agent needs context → use transfer/handoff tools
"""
```

#### LLM-Driven Pattern Selection

The orchestrator doesn't hardcode Pipeline vs Swarm. The LLM **reasons** about
which pattern fits:

| User task | LLM reasoning | Pattern that emerges |
|---|---|---|
| "What time is it?" | "I can answer directly" | Direct (no tools) |
| "What's AAPL stock price?" | "I need the stock API tool" | Single tool call |
| "Research AAPL and write a report" | "Step 1: research, Step 2: write using research" | Sequential delegation |
| "Compare AAPL and GOOGL stocks" | "Both analyses are independent" | Parallel delegation (2 tool calls in 1 turn) |
| "Help me debug this code" | "This needs back-and-forth with the coder agent" | Single delegation with follow-ups |

The key insight: **Pipeline = sequential delegate calls. Fan-out = parallel
delegate calls in one LLM turn. Swarm = agents with transfer_to_* tools routing
themselves.** All three patterns emerge from the same tool-calling mechanism.

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | REST API tools stored in ETS/DETS (like AgentStore) | Consistent with existing persistence pattern. No DB migration needed. |
| D2 | `HttpTool.to_tool/1` generates closures at runtime | Tool functions must be closures (can't serialize fns). Regenerate on boot from config. |
| D3 | URL template uses `{{param}}` interpolation | Simple, safe (no code eval). Like n8n/Postman variables. |
| D4 | Agent delegate tools regenerated per message send | Agent configs may change between messages. Small cost for correctness. |
| D5 | Orchestrator prompt is dynamic, lists available agents | LLM needs to know what specialists exist to reason about delegation. |
| D6 | No explicit Pipeline/Swarm selection in UI | The LLM reasons about patterns. Users define agents and tools; orchestration is emergent. |
| D7 | All tool sources flattened into single `[Tool]` list | LLM can't distinguish tool sources — they're all just callable functions. Unified is simpler. |
| D8 | `AgentBridge` is stateless module, not GenServer | No state to manage — it reads AgentStore and builds tools on demand. |

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/http_tool.ex` | HTTP tool definition struct + `to_tool/1` runtime conversion |
| Create | `lib/agent_ex/http_tool_store.ex` | ETS/DETS persistence for HTTP tool configs |
| Create | `lib/agent_ex/agent_bridge.ex` | Convert AgentStore agents → delegate tools for orchestrator |
| Create | `lib/agent_ex/tool_assembler.ex` | Assemble all tool sources into unified `[Tool]` list per user |
| Create | `lib/agent_ex_web/live/http_tool_builder_live.ex` | REST API tool builder form |
| Create | `lib/agent_ex_web/live/http_tool_builder_live.html.heex` | Template |
| Create | `lib/agent_ex_web/components/http_tool_components.ex` | HTTP tool form fields, parameter table, test panel |
| Modify | `lib/agent_ex_web/live/tools_live.ex` | Add "HTTP API" tab, link to HTTP tool builder |
| Modify | `lib/agent_ex_web/live/tools_live.html.heex` | Template update for HTTP tab |
| Modify | `lib/agent_ex_web/live/chat_live.ex` | Replace `default_tools()` with `ToolAssembler.assemble/2`, use orchestrator prompt |
| Modify | `lib/agent_ex/application.ex` | Add `HttpToolStore` to supervision tree |
| Modify | `lib/agent_ex_web/router.ex` | Add `/tools/http/new`, `/tools/http/:id/edit` routes |

### Implementation Order

```text
5b-A: HttpTool struct + HttpToolStore + UI builder form
  │
  ├─ Can be used standalone (REST API tools in chat without agents)
  │
5b-B: AgentBridge + ToolAssembler
  │
  ├─ Connects AgentStore → delegate tools
  ├─ Unifies all tool sources into single list
  │
5b-C: Chat Orchestrator integration
  │
  ├─ ChatLive uses ToolAssembler instead of default_tools()
  ├─ Dynamic orchestrator system prompt with agent descriptions
  └─ EventLoop.run receives full unified tool list
```

### ToolAssembler — The Unification Layer

```elixir
defmodule AgentEx.ToolAssembler do
  @moduledoc """
  Assembles all tool sources into a unified [Tool] list for a user.
  Called on each message send to get the freshest tool set.

  Sources:
  1. Built-in utility tools (time, system info)
  2. HTTP API tools (from HttpToolStore)
  3. MCP server tools (from connected MCP clients)
  4. Plugin tools (from PluginRegistry)
  5. Agent delegate tools (from AgentBridge)
  """

  alias AgentEx.{AgentBridge, HttpToolStore, Tool}

  def assemble(user_id, model_client, opts \\ []) do
    builtin = builtin_tools()
    http_tools = http_api_tools(user_id)
    # mcp_tools = mcp_connected_tools(user_id)   # future
    # plugin_tools = plugin_attached_tools(user_id)  # future

    available = builtin ++ http_tools

    delegate_tools =
      AgentBridge.delegate_tools(user_id, model_client,
        available_tools: available
      )

    available ++ delegate_tools
  end

  def orchestrator_prompt(user_id) do
    agents = AgentEx.AgentStore.list(user_id)

    agent_descriptions =
      Enum.map_join(agents, "\n", fn a ->
        "- **#{a.name}**: #{a.description || a.system_prompt}"
      end)

    if agents == [] do
      "You are a helpful AI assistant."
    else
      \"\"\"
      You are an AI assistant with access to specialist agents and tools.

      For simple questions, answer directly. For complex tasks, decompose
      into steps and delegate to the right specialist. Each specialist runs
      independently and returns a result. You can call multiple specialists
      in one turn if their work is independent.

      Available specialists:
      #{agent_descriptions}
      \"\"\"
    end
  end

  defp builtin_tools do
    [
      Tool.new(
        name: "get_current_time",
        description: "Get the current date and time",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        kind: :read,
        function: fn _args -> {:ok, DateTime.utc_now() |> DateTime.to_string()} end
      )
    ]
  end

  defp http_api_tools(user_id) do
    HttpToolStore.list(user_id)
    |> Enum.map(&AgentEx.HttpTool.to_tool/1)
  end
end
```

### How Chat Changes

```elixir
# Before (Phase 5):
tools = default_tools()  # hardcoded 3 demo tools
system_prompt = "You are a helpful AI assistant."

# After (Phase 5b):
tools = ToolAssembler.assemble(user.id, client)
system_prompt = ToolAssembler.orchestrator_prompt(user.id)
# tools now includes: builtins + HTTP API tools + delegate_to_* for each agent
# system_prompt dynamically lists available specialists
```

### How an Agent's Own Tools Work

Each agent has `tool_ids` in its config. When the chat orchestrator delegates
to an agent via `delegate_to_researcher("Find AAPL news")`, the `AgentBridge`
resolves the agent's own tools:

```text
Chat Orchestrator
  tools: [delegate_to_researcher, delegate_to_analyst, stock_api.get_quote, ...]
  │
  ▼ calls delegate_to_researcher("Find AAPL news")
  │
  ▼ AgentBridge builds Pipe.Agent with researcher's own tools:
    ┌─────────────────────────────────┐
    │ Researcher Agent                │
    │ system: "You are a researcher"  │
    │ tools: [web_search, web_fetch]  │  ← agent's own tool_ids resolved
    │ intervention: [LogHandler]      │
    │                                 │
    │ Runs Pipe.through() → isolated  │
    │ ToolCallerLoop with own tools   │
    └─────────────────────────────────┘
    │
    ▼ Returns research summary to orchestrator
```

---

## Phase 5c — Workflow Engine (Static Pipelines)

### Core Insight

**Not everything needs LLM reasoning.** Many tasks are deterministic data
transformations: fetch JSON → extract fields → filter → transform → output.
Like n8n, users define these visually as node graphs. Data flows through
operators via the pipe operator — no LLM calls, no token cost, predictable
output.

This complements Phase 5b (LLM orchestrator): the chat model can **delegate
to a workflow** just like it delegates to an agent, but the workflow runs
deterministically.

```text
Phase 5b (LLM reasoning):     Phase 5c (Static pipeline):
  User → Orchestrator LLM       User → Workflow Runner
    ↓ reasons about task           ↓ follows defined DAG
    ↓ calls delegate tools         ↓ executes operators
    ↓ each agent uses LLM          ↓ NO LLM calls
    ↓ unpredictable output         ↓ predictable output
    ↓ costs tokens                 ↓ zero token cost
```

### Problem

1. **Simple data tasks waste LLM tokens** — fetching an API, extracting fields,
   and formatting output doesn't need reasoning. But currently the only way to
   chain operations is through LLM tool calling.

2. **No visual workflow builder** — users familiar with n8n/Zapier expect to
   drag nodes, connect them, and see data flow. Current Pipe composition is
   code-only.

3. **No JSON operators** — the codebase has Tool structs but no built-in
   operators for common data transformations (extract, filter, map, merge).

4. **No deterministic execution engine** — `ToolCallerLoop` is designed for
   LLM-driven iteration. Static pipelines need a simpler runner that just
   executes nodes in topological order.

### Solution

#### The Two Worlds

| Aspect | Chat Orchestrator (5b) | Workflow Engine (5c) |
|---|---|---|
| Who decides next step | LLM reasoning | DAG topology |
| Tool selection | LLM picks from available | User defines at build time |
| Data between stages | Natural language strings | Typed JSON objects |
| Cost per run | LLM tokens per stage | Zero (just computation) |
| Output | Unpredictable (creative) | Deterministic (measured) |
| Best for | Complex reasoning, synthesis | Data pipelines, integrations |

**They compose:** A workflow can be wrapped as a tool for the chat orchestrator.
An agent node in a workflow delegates to an LLM. Users choose the right tool
for each job.

#### Workflow Data Model

```elixir
defmodule AgentEx.Workflow do
  defstruct [
    :id,
    :user_id,
    :name,
    :description,
    nodes: [],          # [WorkflowNode.t()]
    edges: [],          # [WorkflowEdge.t()]
    inserted_at: nil,
    updated_at: nil
  ]
end

defmodule AgentEx.Workflow.Node do
  defstruct [
    :id,                # unique within workflow
    :type,              # :trigger | :http_request | :json_extract | :json_transform |
                        # :json_filter | :set | :if_branch | :switch | :code |
                        # :agent | :tool | :merge | :output
    :label,             # display name
    :config,            # type-specific configuration map
    :position           # {x, y} for visual editor
  ]
end

defmodule AgentEx.Workflow.Edge do
  defstruct [
    :id,
    :source_node_id,
    :target_node_id,
    :source_port,       # "output" | "true" | "false" | "case_1" etc.
    :target_port        # "input"
  ]
end
```

#### Built-in Operators

These are the n8n equivalents — pure functions that transform JSON:

```text
┌─────────────────────────────────────────────────────────────┐
│  DATA OPERATORS (no LLM, no side effects)                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  json_extract   — Pull fields from object via path          │
│                   Config: paths: ["data.price", "meta.ts"]  │
│                   In: %{"data" => %{"price" => 42}}         │
│                   Out: %{"price" => 42, "ts" => nil}        │
│                                                             │
│  json_transform — Rename/reshape fields                     │
│                   Config: mappings: [{"old", "new"}, ...]   │
│                   In: %{"price" => 42}                      │
│                   Out: %{"stock_price" => 42}               │
│                                                             │
│  json_filter    — Filter array items by condition           │
│                   Config: path: "items", condition: "> 10"  │
│                   In: %{"items" => [5, 15, 3, 20]}          │
│                   Out: %{"items" => [15, 20]}               │
│                                                             │
│  json_merge     — Deep merge multiple inputs                │
│                   In: [%{"a" => 1}, %{"b" => 2}]            │
│                   Out: %{"a" => 1, "b" => 2}                │
│                                                             │
│  set            — Set static key-value pairs                │
│                   Config: values: %{"status" => "processed"}│
│                   In: %{"data" => 1}                        │
│                   Out: %{"data" => 1, "status" => "proc.."} │
│                                                             │
│  code           — Custom Elixir expression (sandboxed)      │
│                   Config: expression: "Map.put(input, ...)" │
│                   Evaluated in restricted sandbox            │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  FLOW CONTROL OPERATORS                                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  if_branch      — Binary split based on condition           │
│                   Config: path: "status", equals: "active"  │
│                   Ports: "true" and "false"                  │
│                                                             │
│  switch         — Multi-way routing by value                │
│                   Config: path: "type", cases: ["a","b","c"]│
│                   Ports: "case_a", "case_b", "case_c", "def"│
│                                                             │
│  split          — Fan out array items to parallel branches  │
│                   Config: path: "items"                     │
│                   Runs downstream nodes once per item       │
│                                                             │
│  merge          — Collect parallel branch results           │
│                   Waits for all incoming edges              │
│                   Combines into array or merged object      │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  I/O OPERATORS (side effects)                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  trigger        — Manual / cron / webhook start point       │
│                   Config: type, schedule, payload template  │
│                                                             │
│  http_request   — REST API call (uses HttpTool from 5b)     │
│                   Config: method, url, headers, body        │
│                                                             │
│  tool           — Call any registered AgentEx tool          │
│                   Config: tool_name, param_mapping          │
│                                                             │
│  agent          — Delegate to LLM agent (LLM node)         │
│                   Config: agent_id, task_template           │
│                   This is the ONLY node that costs tokens   │
│                                                             │
│  output         — Terminal node, emits workflow result      │
│                   Config: format (json | text | table)      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### Workflow Runner (Static Execution Engine)

```elixir
defmodule AgentEx.Workflow.Runner do
  @moduledoc """
  Executes a workflow DAG deterministically. No LLM calls unless an
  :agent node is encountered. Data flows as JSON maps between nodes.

  Execution:
  1. Topological sort of nodes from trigger → output
  2. Execute each node with its input data
  3. Route output to connected nodes via edges
  4. Branch/merge as defined by flow control operators
  5. Collect output node results
  """

  def run(%Workflow{} = workflow, trigger_data \\ %{}, opts \\ []) do
    run_id = opts[:run_id] || generate_run_id()
    sorted = topological_sort(workflow.nodes, workflow.edges)
    node_map = Map.new(workflow.nodes, &{&1.id, &1})
    edge_map = group_edges_by_source(workflow.edges)

    execute_dag(sorted, node_map, edge_map, %{
      trigger: trigger_data,
      results: %{},
      run_id: run_id
    })
  end

  defp execute_dag([], _nodes, _edges, state), do: {:ok, state.results}

  defp execute_dag([node_id | rest], nodes, edges, state) do
    node = nodes[node_id]
    input = gather_input(node_id, state, edges)

    case execute_node(node, input, state) do
      {:ok, output} ->
        state = put_in(state, [:results, node_id], output)
        broadcast_node_complete(state.run_id, node_id, output)
        execute_dag(rest, nodes, edges, state)

      {:branch, port, output} ->
        # For if/switch: only follow edges matching the port
        state = put_in(state, [:results, node_id], output)
        filtered_rest = filter_branch(rest, edges, node_id, port)
        execute_dag(filtered_rest, nodes, edges, state)

      {:error, reason} ->
        broadcast_node_error(state.run_id, node_id, reason)
        {:error, node_id, reason}
    end
  end
end
```

#### JSON Path + Expression Engine

For referencing data between nodes:

```text
Syntax: {{node_id.path.to.field}}

Examples:
  {{trigger.body.ticker}}           → trigger payload's ticker
  {{http_request_1.data.price}}     → HTTP response nested field
  {{json_extract_1.name}}           → extracted field

In node configs:
  URL: "https://api.example.com/quote/{{trigger.body.ticker}}"
  Condition: "{{http_request_1.status}} == 200"
  Expression: "{{json_extract_1.price}} * {{set_1.multiplier}}"
```

Implemented as simple template interpolation + JSONPath-style field access:

```elixir
defmodule AgentEx.Workflow.Expression do
  @doc "Resolve {{node.path}} references against workflow state."
  def interpolate(template, results) when is_binary(template) do
    Regex.replace(~r/\{\{(\w+)\.(.+?)\}\}/, template, fn _, node_id, path ->
      case get_in(results, [node_id | String.split(path, ".")]) do
        nil -> ""
        value -> to_string(value)
      end
    end)
  end

  @doc "Evaluate simple conditions for if/switch nodes."
  def evaluate_condition(condition, results) do
    # Supports: ==, !=, >, <, contains, matches
    # All values resolved from {{node.path}} references
    # No arbitrary code execution
  end
end
```

#### Visual Workflow Editor

```text
┌─────────────────────────────────────────────────────────────┐
│  Workflows                                       [+ New]    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────┐    ┌──────────────┐    ┌─────────────┐       │
│  │ 📡       │    │ 🔧           │    │ 📤          │       │
│  │ Trigger  ├───▶│ HTTP Request ├───▶│ JSON Extract│       │
│  │ ──────── │    │ ──────────── │    │ ──────────  │       │
│  │ manual   │    │ GET /quote/  │    │ paths:      │       │
│  │          │    │ {{ticker}}   │    │ data.price  │       │
│  └──────────┘    └──────────────┘    │ data.volume │       │
│                                      └──────┬──────┘       │
│                                             │               │
│                                      ┌──────▼──────┐       │
│                                      │ ❓          │       │
│                                      │ IF Branch   │       │
│                                      │ ──────────  │       │
│                                      │ price > 100 │       │
│                                      └──┬──────┬───┘       │
│                                    true │      │ false      │
│                               ┌────────▼┐  ┌──▼────────┐  │
│                               │ 🤖 Agent│  │ ✏️ Set     │  │
│                               │ Analyst │  │ status:   │  │
│                               │ "Analyze│  │ "skipped" │  │
│                               │  this"  │  └──────┬────┘  │
│                               └────┬────┘         │        │
│                                    │         ┌────▼────┐   │
│                                    └────────▶│ 📊      │   │
│                                              │ Output  │   │
│                                              │ JSON    │   │
│                                              └─────────┘   │
│                                                             │
│  Node palette:                                              │
│  [Trigger] [HTTP] [Extract] [Transform] [Filter] [Set]     │
│  [IF] [Switch] [Split] [Merge] [Code] [Agent] [Tool]       │
│  [Output]                                                   │
│                                                             │
│  [Save] [Run Now] [Run History]                             │
└─────────────────────────────────────────────────────────────┘
```

#### Workflow as Tool (Composability)

A saved workflow becomes callable as a tool — both from the chat orchestrator
and from other workflows:

```elixir
defmodule AgentEx.Workflow.Tool do
  @doc "Wrap a workflow as a Tool.t() for use in chat or other workflows."
  def to_tool(%Workflow{} = workflow) do
    # Infer parameters from trigger node config
    trigger_node = find_trigger(workflow)
    params = trigger_params_to_schema(trigger_node)

    Tool.new(
      name: "workflow.#{workflow.id}",
      description: workflow.description || "Run workflow: #{workflow.name}",
      kind: :write,
      parameters: params,
      function: fn args ->
        case Runner.run(workflow, args) do
          {:ok, results} ->
            output_node = find_output(workflow)
            {:ok, Jason.encode!(results[output_node.id])}
          {:error, node_id, reason} ->
            {:error, "Workflow failed at #{node_id}: #{reason}"}
        end
      end
    )
  end
end
```

This means:
- Chat orchestrator can call `workflow.stock_pipeline` as a tool
- Workflows can nest: a workflow node calls another workflow
- Agents inside a workflow use LLM; everything else is deterministic

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Workflows stored in ETS/DETS (WorkflowStore) | Consistent with AgentStore/HttpToolStore pattern. |
| D2 | Nodes are typed operators, not generic "functions" | Predictable behavior, schema-aware connections, better UX. |
| D3 | JSON maps flow between nodes, not strings | Structured data enables field-level connections and validation. |
| D4 | `{{node.path}}` template syntax | Simple, no code eval, familiar from n8n/Postman. |
| D5 | Topological sort for execution order | DAG guarantees no cycles; deterministic execution. |
| D6 | Agent node is the only LLM-calling node | Clear cost boundary. Users see exactly where tokens are spent. |
| D7 | Workflows wrap as Tool.t() | Composable with chat orchestrator and other workflows. |
| D8 | Expression conditions are declarative, not Elixir eval | Security: no arbitrary code execution in conditions. |
| D9 | Code node uses restricted sandbox | Power users get Elixir expressions, but in a safe subset. |
| D10 | Visual editor uses JS canvas + SVG connections | Same pattern planned for Phase 6 flow editor. Share the hook. |

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/workflow.ex` | Workflow + Node + Edge structs |
| Create | `lib/agent_ex/workflow/store.ex` | ETS/DETS persistence for workflows |
| Create | `lib/agent_ex/workflow/runner.ex` | Static DAG execution engine |
| Create | `lib/agent_ex/workflow/operators.ex` | Built-in operator implementations (extract, transform, filter, merge, set, branch, split) |
| Create | `lib/agent_ex/workflow/expression.ex` | `{{node.path}}` interpolation + condition evaluation |
| Create | `lib/agent_ex/workflow/tool.ex` | Wrap workflow as Tool.t() for composability |
| Create | `lib/agent_ex_web/live/workflows_live.ex` | Workflow list + visual editor |
| Create | `lib/agent_ex_web/live/workflows_live.html.heex` | Template |
| Create | `lib/agent_ex_web/components/workflow_components.ex` | Node palette, node cards, edge rendering |
| Create | `assets/js/hooks/workflow_editor.js` | Canvas drag-drop + SVG edge drawing |
| Modify | `lib/agent_ex/application.ex` | Add WorkflowStore to supervision tree |
| Modify | `lib/agent_ex_web/router.ex` | Add `/workflows`, `/workflows/:id` routes |
| Modify | `lib/agent_ex_web/components/layouts/app.html.heex` | Add Workflows nav item |
| Modify | `assets/js/app.js` | Register WorkflowEditor hook |
| Modify | `lib/agent_ex/tool_assembler.ex` | Include workflow tools in assembled tool list |

### Implementation Order

```text
5c-A: Core structs + WorkflowStore + Operators
  │
  ├─ Workflow/Node/Edge structs
  ├─ Expression engine ({{node.path}} interpolation)
  ├─ Built-in operators (extract, transform, filter, set, branch, merge)
  ├─ WorkflowStore (ETS/DETS persistence)
  │
5c-B: Runner + Workflow-as-Tool
  │
  ├─ Topological sort + DAG execution
  ├─ Event broadcasting for run tracking
  ├─ Workflow.Tool.to_tool/1 for composability
  ├─ ToolAssembler integration
  │
5c-C: Visual Editor + UI
  │
  ├─ WorkflowsLive (list + editor)
  ├─ Node palette, drag-drop canvas
  ├─ SVG edge connections
  ├─ Node configuration panels
  ├─ Run button + execution trace
  └─ Sidebar nav integration
```

---

## Phase 6 — Flow Builder + Triggers

### Problem

Users need a visual way to compose multi-agent workflows and trigger them from
sources beyond chat — schedules, webhooks, sensors, MCP events, file changes.
Currently Pipe/Swarm composition and execution are code-only.

### Solution

**Flow Builder** with two modes:

**Pipe Mode** — DAG editor mapping to `AgentEx.Pipe` operations:

| Visual Element | Pipe Operation |
|---|---|
| Trigger node (first in chain) | Trigger adapter → `EventLoop.run` |
| Linear chain of agent cards | `\|> through(a) \|> through(b)` |
| Parallel branch | `\|> fan_out([a, b])` |
| Merge point | `\|> merge(leader)` |
| Orchestrator card with delegates | LLM-composed (delegate tools) |

**Swarm Mode** — agent graph with handoff rules:

| Visual Element | Swarm Config |
|---|---|
| Agent nodes | `Swarm.Agent` definitions |
| Directed edges | `handoffs: ["analyst", "writer"]` |
| Termination node | `termination: {:handoff, "user"}` |
| Intervention gates | Handler pipeline between nodes |

### Trigger System

`EventLoop.run/6` doesn't care who calls it — triggers are adapters that
convert external events into run parameters (messages, agent, tools).

**Trigger Types:**

| Trigger | Source | Backend |
|---|---|---|
| Manual | Chat input or "Run" button | Current `ChatLive` / `RunsLive` |
| Schedule | Cron expression (e.g., `0 9 * * *`) | `TriggerManager` + Erlang `:timer` or `Quantum` |
| Webhook | HTTP POST to generated URL | Phoenix controller → `EventLoop.run` |
| PubSub | Subscribe to internal topic | `Phoenix.PubSub.subscribe` → `EventLoop.run` |
| File watch | Directory change (inotify) | `FileSystem` lib → `EventLoop.run` |
| MCP event | External system notification | `MCP.Client` subscription → `EventLoop.run` |
| Agent chain | One flow's output triggers another | PubSub `:pipeline_complete` → next flow |

**Architecture:**

```text
Trigger (any source)
    │
    ▼
┌──────────────────┐
│ TriggerAdapter   │  Converts trigger event into:
│                  │  - input messages (from payload/template)
│                  │  - agent selection (from flow config)
│                  │  - tool context
├──────────────────┤
│ EventLoop.run/6  │  Same execution path for all triggers.
├──────────────────┤
│ PubSub broadcast │  UI gets events regardless of trigger source.
└──────────────────┘
```

**Flow Builder UI with trigger node:**

```text
┌─────────────────────────────────────────────────────────────┐
│  Flows Tab                                                   │
├─────────────────────────────────────────────────────────────┤
│  [+ Pipe Flow]  [+ Swarm]                                   │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │ Trigger  ├───►│Researcher├───►│ Analyst  │              │
│  │ ──────── │    └──────────┘    └────┬─────┘              │
│  │ cron:    │                        │                     │
│  │ 0 9 * * *│                   ┌────▼─────┐              │
│  └──────────┘                   │ fan_out  │              │
│                                  ├──────────┤              │
│  Trigger types:                 │ Agent A  │              │
│  [manual|cron|webhook|          │ Agent B  │              │
│   pubsub|file|mcp|chain]       └────┬─────┘              │
│                                      │                     │
│                                 ┌────▼─────┐              │
│                                 │  merge   │              │
│                                 │ → Writer │              │
│                                 └──────────┘              │
│                                                              │
│  [Save Flow]  [Run Now]  [Enable Trigger]                   │
└─────────────────────────────────────────────────────────────┘
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/flow_config.ex` | Flow definition struct (pipe/swarm, agents, connections, trigger) |
| Create | `lib/agent_ex/flow_store.ex` | ETS/DETS persistence for flow configs |
| Create | `lib/agent_ex/trigger/trigger_manager.ex` | GenServer: start/stop triggers, fire → EventLoop |
| Create | `lib/agent_ex/trigger/trigger_adapter.ex` | Behaviour for trigger types |
| Create | `lib/agent_ex/trigger/cron_trigger.ex` | Cron schedule trigger (Erlang `:timer` or Quantum) |
| Create | `lib/agent_ex/trigger/webhook_trigger.ex` | Generates URL, receives POST |
| Create | `lib/agent_ex/trigger/pubsub_trigger.ex` | Subscribes to PubSub topic |
| Create | `lib/agent_ex/trigger/file_trigger.ex` | Watches directory for changes |
| Create | `lib/agent_ex/trigger/chain_trigger.ex` | Listens for `:pipeline_complete` from another flow |
| Create | `lib/agent_ex_web/live/flows_live.ex` | Flow list + visual builder |
| Create | `lib/agent_ex_web/live/flows_live.html.heex` | Template |
| Create | `lib/agent_ex_web/live/execution_live.ex` | Real-time execution viewer |
| Create | `lib/agent_ex_web/live/execution_live.html.heex` | Template |
| Create | `lib/agent_ex_web/components/flow_components.ex` | Agent nodes, SVG edges, trigger cards |
| Create | `lib/agent_ex_web/controllers/webhook_controller.ex` | Receives webhook POST, fires trigger |
| Create | `lib/agent_ex/event_loop/pipe_event_loop.ex` | Per-stage event broadcasting |
| Create | `assets/js/hooks/flow_editor.js` | Drag-and-drop canvas, SVG connections |
| Modify | `lib/agent_ex/application.ex` | Add TriggerManager to supervision tree |
| Modify | `lib/agent_ex_web/router.ex` | Add `/flows`, `/execution/:run_id`, `/webhook/:id` |
| Modify | `lib/agent_ex_web/components/layouts/app.html.heex` | Sidebar nav |
| Modify | `assets/js/app.js` | Register FlowEditor hook |

---

## Phase 7 — Run View + Memory Inspector

### Problem

The current chat view is a generic LLM chat that doesn't show AgentEx's internal
workings. No visibility into execution traces, agent handoffs, memory context
injection, or the knowledge graph. Runs triggered by non-chat sources (cron,
webhook, file watch) have no UI at all.

### Solution

**Run View** — replaces the chat as the primary interaction. Task-oriented input
("What do you need done?") with a live execution trace showing the full
Sense-Think-Act cycle, tool calls, handoffs, and memory context. Also serves as
the viewer for automated runs triggered by cron/webhook/etc.

**Memory Inspector** — per-agent memory browser across all tiers with knowledge
graph visualization.

### Design — Run View

```text
┌─────────────────────────────────────────────────────────────┐
│  Runs Tab                                                    │
├─────────────────────────────────────────────────────────────┤
│ Task: [Analyze Q4 earnings for AAPL            ] [Run] [Stop]│
│ Flow: [Research Pipeline ▼]  Agent: [auto ▼]                │
│ Triggered by: manual / cron (09:00 daily) / webhook #a3f2   │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ ● THINK — querying gpt-5.4 (8 msgs)                        │
│ ● SENSE — get_stock_data({ticker: "AAPL"})                  │
│   └─ Result: {price: 245.12, ...}                           │
│ ● THINK — analyzing with context                            │
│   Memory: [Tier 2: prefers detailed] [Tier 3: prior AAPL]  │
│ ○ HANDOFF → Analyst                                         │
│ ● THINK — analyst reasoning...                              │
│ ○ HANDOFF → Writer                                          │
│ ● THINK — composing report                                  │
│                                                              │
│ ── Final Output ──                                          │
│ AAPL Q4 earnings show 12% growth...                         │
│                                                              │
│ [Follow-up input for conversation continuation]              │
│                                                              │
│ ── Run History ──                                           │
│ run-1234  manual   3.2s  completed  "Analyze AAPL..."       │
│ run-1230  cron     5.1s  completed  "Daily market scan"     │
│ run-1228  webhook  1.8s  error      "PR review #412"        │
└─────────────────────────────────────────────────────────────┘
```

### Design — Memory Inspector

```text
┌─────────────────────────────────────────────────────────────┐
│  Memory Tab                  Agent: [Researcher ▼]           │
├──────────┬──────────┬──────────┬────────────────────────────┤
│ Tier 1   │ Tier 2   │ Tier 3   │ Knowledge Graph            │
│ Working  │ Persist  │ Semantic │ Entities                   │
├──────────┴──────────┴──────────┴────────────────────────────┤
│ Tier 1: Recent conversations                                │
│   session-4559: 12 messages, 2.1k tokens                   │
│   session-4558: 8 messages, 1.4k tokens                    │
│                                                              │
│ Tier 2: Stored facts                                        │
│   expertise = "data analysis"    [edit] [forget]            │
│   style = "concise"              [edit] [forget]            │
│   + Remember new fact                                       │
│                                                              │
│ Tier 3: Semantic search                                     │
│   [Search memories...                    ] [Search]         │
│   "AAPL analysis" → 3 results (0.92, 0.87, 0.71 relevance)│
│                                                              │
│ Knowledge Graph:                                             │
│   [Search entities...                    ] [Search]         │
│   AAPL ──[traded_on]──▶ NASDAQ                             │
│     └──[has_ceo]──▶ Tim Cook                               │
│     └──[competitor]──▶ MSFT                                │
└─────────────────────────────────────────────────────────────┘
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex_web/live/runs_live.ex` | Task input + execution trace + run history |
| Create | `lib/agent_ex_web/live/runs_live.html.heex` | Template |
| Create | `lib/agent_ex_web/components/run_components.ex` | Trace timeline, handoff arrows, memory badges |
| Create | `lib/agent_ex_web/live/memory_live.ex` | Tabbed memory inspector |
| Create | `lib/agent_ex_web/live/memory_live.html.heex` | Template |
| Create | `lib/agent_ex_web/live/memory/working_memory_component.ex` | Tier 1 session browser |
| Create | `lib/agent_ex_web/live/memory/persistent_memory_component.ex` | Tier 2 key-value editor |
| Create | `lib/agent_ex_web/live/memory/semantic_memory_component.ex` | Tier 3 search + results |
| Create | `lib/agent_ex_web/live/memory/knowledge_graph_component.ex` | d3-force graph visualization |
| Create | `lib/agent_ex_web/components/memory_components.ex` | Cards, search bar, tier badges |
| Create | `assets/js/hooks/graph_viewer.js` | d3-force graph hook |
| Modify | `lib/agent_ex_web/router.ex` | Add `/runs`, `/memory` |
| Modify | `lib/agent_ex_web/components/layouts/app.html.heex` | Tabbed workspace nav |
| Modify | `assets/js/app.js` | Register GraphViewer hook |
| Modify | `lib/agent_ex_web/live/chat_live.ex` | Refactor into Runs view or keep as simple mode |

---

## Phase 8 — Hybrid Bridge (Remote Computer Use)

### Core Insight

**Agents need to operate on the user's machine, not the server.** When AgentEx
is deployed to a server, tools like `ShellExec` and `FileSystem` execute on the
server — not where the user's code, files, and environment live. This is the
fundamental challenge of computer-use agents.

The solution: a **lightweight bridge** that runs on the user's machine, connects
to the AgentEx server via WebSocket, and executes tool calls locally. The BEAM VM
can handle millions of concurrent WebSocket connections, so this scales to every
user having a persistent real-time channel.

```text
Server (AgentEx)                         User's Machine
┌──────────────────────────┐            ┌──────────────────────────┐
│  Phoenix + Channels (WSS) │            │  AgentEx Bridge (binary) │
│  ├── LLM orchestration    │            │  ├── MCP Server (local)  │
│  ├── Agent configs        │◄── WSS ──►│  │   ├── shell executor  │
│  ├── Memory tiers         │  (HMAC    │  │   ├── file I/O        │
│  ├── Web UI               │  signed)  │  │   └── sandbox enforce │
│  ├── Bridge Registry      │            │  ├── Local policy file   │
│  │   └── routes tool calls│            │  ├── Write confirmation  │
│  └── Result Sanitizer     │            │  └── Reconnect + backoff│
│                            │            │                          │
└──────────────────────────┘            └──────────────────────────┘
```

### Problem

1. **Server-side tools can't reach user machines** — `System.cmd("ls", [])` runs
   on the server. File reads see the server's filesystem. The agent is blind to
   the user's actual workspace.

2. **Claude Code solves this by running locally** — but that requires the user
   to install Elixir/OTP and run the full Phoenix stack. Not viable for a
   multi-user deployed platform.

3. **SSH is fragile and insecure** — requires key management, firewall config,
   and exposes the full machine. Not suitable for a web platform.

4. **Containers don't solve "my machine"** — GitHub Codespaces gives you a VM,
   not your actual laptop with your dotfiles, running services, and local state.

### Solution

Three deployment modes that coexist:

| Mode | How | When |
|---|---|---|
| **Local** | User runs AgentEx on `localhost` | Dev/personal use, full local access |
| **Bridge** | Server-deployed + bridge on user's machine | Production, agents operate on user's real machine |
| **Server-only** | Server-deployed, no bridge | API-only agents, cloud tools, no local access needed |

The bridge is a **single pre-compiled binary** (packaged via Burrito) that:

1. Reads auth token from `~/.agentex/token` (never CLI args — prevents `ps aux` leakage)
2. Opens a persistent Phoenix Channel over **WSS only** (TLS enforced)
3. Receives tool calls, validates against **bridge-local policy** (user's last line of defense)
4. **Prompts the user for confirmation** on write operations (like Claude Code's `y/n`)
5. Executes locally within sandbox, returns size-limited + secret-scrubbed results

### Security Model

#### Threat Model & Trust Boundaries

```text
LLM (untrusted) → Server (trusted) → WSS → Bridge (semi-trusted) → User's Machine

Trust boundary 1: LLM → Server
  Mitigated by: Intervention pipeline (handlers gate every tool call)

Trust boundary 2: Server → Bridge
  Mitigated by: HMAC-signed messages, bridge-local policy, write confirmation

Trust boundary 3: Bridge → User's Machine
  Mitigated by: Sandbox enforcement, secret scrubbing, result size limits
```

#### Security Principle: Bridge Has Final Authority

The bridge is the user's last line of defense. A compromised server should NOT
be able to execute arbitrary commands on the user's machine. The bridge enforces:

1. **Local policy file** (`~/.agentex/policy.json`) — bridge-side allowlist that
   the server cannot override. Defines which tools are permitted, which paths
   are accessible, and which commands are blocked. This is the user's config,
   not the server's.

2. **Write confirmation** — all `:write` tool calls require user confirmation
   in the bridge terminal before execution (unless `--auto-approve-reads` flag).
   Like Claude Code's permission prompts.

3. **Result sanitization** — bridge scrubs known secret patterns from results
   before sending back to the server.

```text
┌─────────────────────────────────────────────────────────────────┐
│  DEFENSE IN DEPTH: Every tool call passes FOUR gates            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Gate 1: Intervention Pipeline (server-side)                    │
│    AgentConfig.intervention_pipeline handlers                    │
│    PermissionHandler → WriteGateHandler → LogHandler             │
│    First deny wins. Rejects before call reaches bridge.          │
│                                                                  │
│  Gate 2: Server Sandbox Validation (server-side)                │
│    Validates tool name + args against AgentConfig.sandbox        │
│    Checks disallowed_commands, root_path constraints             │
│    Rejects before sending to bridge.                             │
│                                                                  │
│  Gate 3: Bridge Local Policy (bridge-side)                      │
│    ~/.agentex/policy.json — user-controlled, server can't        │
│    override. Additional path restrictions, command blocks.        │
│    Rejects even if server says approve.                          │
│                                                                  │
│  Gate 4: User Confirmation (bridge-side, write tools only)      │
│    Bridge prompts: "Agent wants to run: rm old.log [y/N]"        │
│    User must type 'y' to proceed.                                │
│    Timeout → auto-reject. No silent execution of writes.         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Token Security

```text
Token lifecycle:
  1. User generates token in UI → stored hashed in DB (like session tokens)
  2. Token is scoped: {user_id, allowed_agent_ids, expires_at}
  3. User saves token to ~/.agentex/token (file, not CLI arg)
  4. Bridge reads token from file on startup
  5. On first connect, server binds token to bridge fingerprint (machine ID)
  6. Subsequent connections from different fingerprint → reject + alert user
  7. Short TTL (24h default) + refresh mechanism for long sessions
  8. User can revoke from UI → immediate disconnect

What the token CANNOT do:
  - Access other users' bridges
  - Bypass bridge-local policy
  - Expand its own agent scope
  - Survive TTL expiry without refresh
```

#### Transport Security

| Concern | Mitigation |
|---|---|
| Plaintext WebSocket | WSS enforced at socket level — `ws://` connections rejected |
| Message tampering | HMAC-SHA256 signing on tool_call/tool_result using session key derived at handshake |
| MITM / DNS hijacking | Bridge pins server TLS certificate fingerprint on first connection (TOFU model) |
| Connection exhaustion | Rate-limit: max 10 connection attempts per IP per minute before auth |
| Reconnect storms | Exponential backoff with jitter: 1s → 2s → 4s → ... → 60s cap, ±30% jitter |

#### Command Execution Security

The denylist-only approach is insufficient (`rm` blocked but `perl -e 'unlink()'`
bypasses it). The bridge uses a **layered command filter**:

```text
Layer 1: Binary denylist (from AgentConfig.sandbox.disallowed_commands)
  Blocks: rm, mv, dd, mkfs, kill, shutdown, reboot, etc.

Layer 2: Argument pattern filter (bridge-side)
  Blocks dangerous argument patterns regardless of binary:
    - Recursive delete flags: -rf, --recursive combined with --force
    - Device paths: /dev/sd*, /dev/null (as output), /dev/zero
    - System directories: /etc, /boot, /sys, /proc as write targets
    - SQL destructive: DROP, DELETE without WHERE, TRUNCATE
    - Shell metachar injection: backticks, $(), pipe to rm/dd

Layer 3: Full-path binary resolution
  Resolves binary to absolute path via `which`/`System.find_executable`
  Checks resolved path, not just the name. `/usr/bin/rm` and `rm` both
  match the denylist. Symlinks to denied binaries also caught.

Layer 4: Write confirmation (user sees exact command before execution)
  Bridge shows: "Agent wants to run: git push origin main [y/N]"
  User decides. No silent execution of write commands.
```

#### Data Protection

| Concern | Mitigation |
|---|---|
| Sensitive files in results | Bridge-side denylist: never read `.env`, `*.pem`, `*_key`, `id_rsa`, `*.p12`, `.git/config` with credentials, `~/.ssh/*`, `~/.aws/credentials` |
| Secrets in tool output | Regex scrubber strips API keys, tokens, passwords from results before sending: `sk-[a-zA-Z0-9]{20,}`, `Bearer [a-zA-Z0-9._-]+`, `password[=:]\s*\S+` |
| Result size flooding | Max 1MB per tool result. Truncated with `"[truncated: 1MB limit]"` marker |
| Tool args leaking secrets | Server-side LogHandler redacts known secret patterns in args before persisting to conversation history |

### Autonomous Execution Mode (Memory-Guided RL Loops)

#### Core Insight: Sandbox Replaces Confirmation

For autonomous research agents that iterate in a loop — training models,
running experiments, evaluating results — requiring human confirmation on every
write operation kills the loop. The insight from Karpathy's auto-research
concept, Sakana AI's AI Scientist, and the Reflexion pattern is:

**The sandbox IS the security boundary. Budget constraints replace human approval.**

If `root_path = /home/user/experiments/run-42/` and destructive commands are
blocked, the agent literally cannot escape. It can freely read, write, execute,
and iterate within that boundary — exactly like a containerized ML training job.

#### Execution Modes

`AgentConfig.execution_mode` controls which gates are active:

| Mode | Gate 1 (Intervention) | Gate 2 (Server Sandbox) | Gate 3 (Bridge Policy) | Gate 4 (Confirmation) | Gate 4b (Budget) |
|---|---|---|---|---|---|
| **`:interactive`** (default) | Active | Active | Active | **Active** — user confirms writes | N/A |
| **`:autonomous`** | Active | Active | Active | **Skipped** — no confirmation | **Active** — budget enforced |

In autonomous mode, Gate 4 (user confirmation) is replaced by Gate 4b (budget
enforcement). The agent runs freely within its sandbox until it exhausts its
budget.

#### Budget Constraints

`AgentConfig.budget` defines the autonomy boundary:

```elixir
%AgentConfig{
  execution_mode: :autonomous,
  sandbox: %{
    "root_path" => "/home/user/experiments/run-42",
    "disallowed_commands" => ["rm", "mv", "dd", "kill", "drop", "truncate"]
  },
  budget: %{
    "max_iterations" => 50,         # max ToolCallerLoop iterations
    "max_wall_time_s" => 14400,     # 4 hours
    "max_cost_usd" => 20.0          # LLM token cost cap
  }
}
```

When any budget limit is reached, the agent stops gracefully:
1. Current tool call completes (no mid-execution kill)
2. Agent saves final state to Tier 2 memory
3. Session summary promoted to Tier 3 via `Promotion.close_session_with_summary`
4. User notified: "Agent 'researcher' completed — budget exhausted (50/50 iterations)"

#### The RL Loop: Memory as Reward Signal

AgentEx's existing architecture maps directly to the reinforcement learning
pattern used by auto-research systems:

```text
┌──────────────────────────────────────────────────────────────────┐
│  AUTONOMOUS RESEARCH LOOP (ToolCallerLoop + Memory)              │
│                                                                   │
│  ┌─────────┐    ┌──────────┐    ┌──────────┐    ┌───────────┐  │
│  │ THINK   │    │  ACT     │    │ OBSERVE  │    │ REMEMBER  │  │
│  │ LLM     │───▶│ Write    │───▶│ Run      │───▶│ save_     │  │
│  │ reasons │    │ code/    │    │ experiment│    │ memory()  │  │
│  │ about   │    │ config   │    │ read     │    │ to Tier 3 │  │
│  │ next    │    │ (sandbox)│    │ metrics  │    │           │  │
│  │ step    │    │          │    │          │    │ Tier 2:   │  │
│  └────▲────┘    └──────────┘    └──────────┘    │ best_score│  │
│       │                                          │ strategy  │  │
│       │         ┌──────────────────────────┐     └─────┬─────┘  │
│       │         │ ContextBuilder.build()   │           │        │
│       └─────────│ Injects past outcomes:   │◄──────────┘        │
│                 │ - Tier 2: best_score=0.92│   Next iteration   │
│                 │ - Tier 3: "approach X    │   gets this context│
│                 │   worked, Y didn't"      │                    │
│                 │ - KG: entity relations   │                    │
│                 └──────────────────────────┘                    │
│                                                                   │
│  Terminates when: budget exhausted OR LLM returns final answer   │
└──────────────────────────────────────────────────────────────────┘
```

**How each memory tier serves the loop:**

| Tier | Role | Example |
|---|---|---|
| **Tier 1 (Working)** | Current iteration's conversation | Tool calls, observations, reasoning |
| **Tier 2 (Persistent)** | Iteration-level state registers | `best_score=0.92`, `iterations_completed=15`, `last_strategy=approach_X` |
| **Tier 3 (Semantic)** | Searchable outcome history | "Iteration 7: dropout 0.3 gave 84.1% val acc — best so far" |
| **Knowledge Graph** | Shared entity knowledge | "AAPL → traded_on → NASDAQ", "ResNet → uses → skip connections" |

**The feedback loop:** Iteration N stores outcomes in Tier 3 via `save_memory`
tool → Iteration N+1 starts → `ContextBuilder.build` queries Tier 3 with the
current task → semantically similar past outcomes are injected as system
messages → LLM makes informed decisions → better experiments → better outcomes
stored → Iteration N+2 has even richer context.

This is **in-context reinforcement learning** — the LLM's "policy" improves
not through weight updates, but through accumulating richer context from memory.

#### Two-Level Reward: Step + Episode

Autonomous agents need reward signals at two granularities:

| Level | RL Analogy | When | What's Captured | Stored In |
|---|---|---|---|---|
| **Step reward** | TD(0) | After every SENSE cycle (tool result) | Structured observation: tool, args, result, delta | Tier 2 (auto) |
| **Episode reward** | Monte Carlo return | End of session / budget exhaustion | Strategic summary: what worked, what failed, key insights | Tier 3 (auto) |

**Step reward** gives the agent fine-grained feedback within a session.
**Episode reward** gives strategic guidance across sessions. Both are needed.

##### Step-Level Observation Logger

The problem with relying solely on the LLM calling `save_memory` is that it
might forget. For autonomous agents, every tool result is automatically logged
as a structured observation. This hooks into `Sensing.sense/3` which already
processes every tool result:

```elixir
defmodule AgentEx.Bridge.ObservationLogger do
  @moduledoc """
  Auto-logs every tool result as a structured observation for autonomous agents.
  Hooks into the Sensing pipeline after tool results are collected.

  Only active when execution_mode == :autonomous.
  """

  alias AgentEx.Memory

  @doc """
  Log a tool call result as a structured step observation.
  Called after Sensing step 2 (process results) for autonomous agents.
  """
  def log_step(agent_id, iteration, %{name: name, arguments: args}, result, prev_metrics) do
    observation = %{
      iteration: iteration,
      tool: name,
      args: summarize_args(args),
      result: summarize_result(result),
      delta: compute_delta(result, prev_metrics),
      timestamp: DateTime.utc_now()
    }

    # Tier 2: structured key-value for immediate access
    key = "step_#{iteration}_#{name}"
    Memory.remember(agent_id, key, Jason.encode!(observation), "observation")

    # Update running metrics if result contains numeric outcomes
    maybe_update_metrics(agent_id, result)

    observation
  end

  defp summarize_args(args) when byte_size(args) > 500 do
    String.slice(args, 0, 500) <> "..."
  end
  defp summarize_args(args), do: args

  defp summarize_result({:ok, result}) when byte_size(result) > 1000 do
    String.slice(result, 0, 1000) <> "..."
  end
  defp summarize_result(result), do: result

  defp compute_delta(result, prev_metrics) do
    # Extract numeric values from result, compare against prev_metrics
    # Returns %{"val_acc" => +0.02, "loss" => -0.05} or nil
    case extract_metrics(result) do
      nil -> nil
      current -> diff_metrics(current, prev_metrics)
    end
  end
end
```

This gives the agent a structured log it can reason about:

```text
ContextBuilder injects into next THINK:

## Recent Step Observations
| Step | Tool | Result | Delta |
|------|------|--------|-------|
| 7.run_experiment | run_training | val_acc=0.82 | +0.01 |
| 7.read_metrics   | read_file    | loss=0.34    | -0.03 |
| 8.run_experiment | run_training | val_acc=0.84 | +0.02 |
| 8.read_metrics   | read_file    | loss=0.31    | -0.03 |

Trend: val_acc improving +0.015/step, loss decreasing
```

##### Episode-Level Session Summary

Already implemented via `Memory.Promotion.close_session_with_summary/3`. For
autonomous agents, this fires automatically on budget exhaustion:

```text
Budget exhausted (50/50 iterations) → auto-triggers:
  1. Promotion.close_session_with_summary(agent_id, session_id, model_client)
     → LLM summarizes: "Best result: 84% with dropout 0.3 and lr=0.001.
        Key insight: learning rates above 0.005 diverge. Batch normalization
        helped more than layer normalization. Unexplored: weight decay."
     → Stored in Tier 3 as vector-embedded summary

  2. Memory.remember(agent_id, "session_outcome", outcome_json, "episode")
     → Tier 2: structured final state for quick lookup
```

##### How Both Levels Flow Together

```text
Session 1 (50 iterations):
  Step 1:  THINK → "try lr=0.01"
           SENSE → run_experiment → val_acc=0.79
           [auto-log: {step: 1, tool: run_experiment, result: 0.79, delta: nil}]
  Step 2:  THINK → "0.79 is low, lr too high" ← reads step 1 from Tier 2
           SENSE → run_experiment → val_acc=0.84
           [auto-log: {step: 2, result: 0.84, delta: +0.05}]
  Step 3:  THINK → "big improvement! try adding dropout" ← reads delta +0.05
           ...
  Step 50: Budget exhausted
           [auto-summary → Tier 3: "lr=0.001 optimal, dropout=0.3 best"]
           [auto-save → Tier 2: session_outcome={best: 0.91, params: {...}}]

Session 2 (new experiment, 50 more iterations):
  ContextBuilder.build() injects:
    Tier 2: best_score=0.91, best_lr=0.001       ← step-level state
    Tier 3: "Session 1: lr=0.001 optimal..."     ← episode-level insight
  Step 1:  THINK → "I know lr=0.001 works and dropout=0.3 is best.
                     Session 1 didn't try weight decay. Let me try that."
           ← informed by BOTH step state AND episode summary
```

#### Anomaly Observer (Background Safety Net)

Even in autonomous mode, a background process monitors for suspicious behavior:

```text
Anomaly triggers (any one pauses the agent and notifies user):
  - Repeated identical failures (agent stuck in a loop)
  - Resource usage spike (CPU/memory exceeds 2x baseline)
  - Metrics that are unreasonably good (possible data leakage)
  - Attempts to access paths outside sandbox (caught by Gate 2/3)
  - Cost approaching budget limit (80% warning, 100% hard stop)
  - Wall time approaching limit (80% warning)
```

The observer runs as a separate BEAM process, monitoring the agent's tool calls
and results via PubSub. It does NOT block tool execution — it observes
asynchronously and can pause the agent between iterations if needed.

#### Autonomous Mode Requires Sandbox

The UI enforces: **autonomous mode cannot be enabled without a configured
sandbox.** If `execution_mode: :autonomous` but `sandbox.root_path` is empty,
the agent editor shows a validation error:

```text
⚠ Autonomous mode requires a sandbox boundary.
  Set a root directory to confine this agent's operations.
```

This prevents users from accidentally creating an autonomous agent with
unrestricted access.

### Session Lifecycle & Episode Promotion

#### The Problem: Interactive Sessions Never "End"

Autonomous agents have a clean lifecycle — budget exhaustion triggers session
summary and cleanup. But interactive chat sessions have **no endpoint**:

```text
Current state:
  User opens conversation → Memory.start_session() ✓
  User chats             → Memory.add_message()     ✓
  User closes browser    → (nothing happens)         ✗
  User logs out          → (nothing happens)         ✗
  User walks away        → (memory server runs forever) ✗

  Promotion.close_session_with_summary is NEVER called from chat.
  Working memory servers are NEVER cleaned up.
  Episode rewards are NEVER generated for interactive sessions.
```

This means interactive conversations **never produce Tier 3 episode summaries**,
so cross-session learning doesn't work for the most common use case.

#### Solution: Layered Session Lifecycle

Five layers, each catching what the one above misses:

```text
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: Explicit Close (best signal, lowest coverage)          │
│  User clicks "Close & Summarize" in the chat UI.                │
│  Triggers: Promotion → Tier 3 summary → stop working memory     │
│  Catches: intentional session end                                │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: Conversation Switch (good signal, natural)             │
│  User opens a different conversation or clicks "New Chat".       │
│  Previous session promoted after 60s delay (debounce).           │
│  Catches: natural context switches                               │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3: Idle Timeout (automatic, catches most cases)           │
│  No messages for 30 minutes → WorkingMemory.Server :timeout.    │
│  GenServer built-in timeout — every message resets the timer.    │
│  Catches: browser close, walk away, lost connection, forgotten   │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4: Logout / Session Expiry (cleanup sweep)                │
│  On explicit logout: promote all user's active sessions.         │
│  On auth token expiry: background sweep finds orphaned sessions. │
│  Catches: explicit logout, cookie expiry, idle auth timeout      │
├─────────────────────────────────────────────────────────────────┤
│  Layer 5: Daily Garbage Collection (safety net)                  │
│  Periodic task finds WorkingMemory servers older than 24h with   │
│  no recent messages. Promotes and terminates.                    │
│  Catches: leaked processes, server restarts, edge cases          │
└─────────────────────────────────────────────────────────────────┘
```

| Scenario | Caught By |
|---|---|
| User clicks "done" | Layer 1 |
| User starts new conversation | Layer 2 |
| User reads results and walks away | Layer 3 |
| User closes browser/tab | Layer 3 |
| User explicitly logs out | Layer 4 |
| Auth cookie expires (15 min idle) | Layer 4 |
| Server restarts, orphaned processes | Layer 5 |
| Working memory leak from edge cases | Layer 5 |

#### Layer 3: Idle Timeout (the workhorse)

This catches the majority of cases — users rarely click "done" but always
eventually stop typing. The `WorkingMemory.Server` is already a GenServer.
Adding an idle timeout uses its built-in mechanism:

```elixir
defmodule AgentEx.Memory.WorkingMemory.Server do
  use GenServer

  @idle_timeout_ms 30 * 60 * 1000  # 30 minutes

  # Every reply resets the timeout
  @impl true
  def handle_call({:add_message, msg}, _from, state) do
    state = %{state | messages: state.messages ++ [msg]}
    {:reply, :ok, state, @idle_timeout_ms}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, {:ok, state.messages}, state, @idle_timeout_ms}
  end

  # Timeout fires when no messages arrive for 30 min
  @impl true
  def handle_info(:timeout, state) do
    if length(state.messages) >= 2 do
      # Only promote if there's a real conversation (not just system msg)
      Task.start(fn ->
        Promotion.close_session_with_summary(
          state.agent_id,
          state.session_id,
          ModelClient.new(model: "gpt-4o-mini")
        )
      end)
    else
      # Too short to summarize — just stop
      :ok
    end

    {:stop, :normal, state}
  end
end
```

The timeout resets on **every** operation — `add_message`, `get_messages`, etc.
If the user sends a message at 2:00 PM, the timeout fires at 2:30 PM unless
another message arrives first. No polling, no cron — GenServer handles it
natively.

#### Layer 2: Conversation Switch

When the user navigates to a different conversation in `ChatLive`, the previous
session gets promoted. A 60s debounce prevents rapid switching from triggering
multiple promotions:

```elixir
# In ChatLive.handle_params/3, when loading a new conversation:
defp maybe_promote_previous(socket) do
  prev = socket.assigns[:current_session]

  if prev && prev.agent_id && prev.session_id do
    # Debounce: schedule promotion 60s from now
    # If user switches back within 60s, cancel via Process.cancel_timer
    timer = Process.send_after(self(), {:promote_previous, prev}, 60_000)
    assign(socket, promote_timer: timer)
  else
    socket
  end
end
```

#### Layer 4: Logout Cleanup

On explicit logout, broadcast a `:user_sessions_closing` message that triggers
promotion of all the user's active working memory sessions:

```elixir
# In UserAuth.log_out_user/1, before deleting tokens:
defp promote_active_sessions(user_id) do
  agent_id = "user_#{user_id}_chat"

  # Find all active working memory servers for this user
  WorkingMemory.Supervisor.list_sessions(agent_id)
  |> Enum.each(fn session_id ->
    Task.start(fn ->
      Promotion.close_session_with_summary(agent_id, session_id, model_client)
    end)
  end)
end
```

For auth token expiry (silent — no logout event), Layer 3 (idle timeout) or
Layer 5 (daily GC) catches it.

#### Layer 5: Daily Garbage Collection

A periodic task sweeps for orphaned working memory servers:

```elixir
defmodule AgentEx.Memory.SessionGC do
  @moduledoc """
  Periodic garbage collector for orphaned working memory sessions.
  Runs every hour. Promotes and terminates sessions with no activity
  in 24h.
  """
  use GenServer

  @sweep_interval_ms 60 * 60 * 1000  # 1 hour
  @max_idle_ms 24 * 60 * 60 * 1000   # 24 hours

  def init(_) do
    schedule_sweep()
    {:ok, %{}}
  end

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    WorkingMemory.Supervisor.list_all_sessions()
    |> Enum.each(fn {agent_id, session_id, last_activity} ->
      if now - last_activity > @max_idle_ms do
        Task.start(fn ->
          Promotion.close_session_with_summary(agent_id, session_id, model_client)
        end)
      end
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```

#### Unified Session Lifecycle: Both Modes

```text
INTERACTIVE MODE                    AUTONOMOUS MODE
─────────────────                   ─────────────────
Session start:                      Session start:
  User opens conversation             Agent run starts
  Memory.start_session()               Memory.start_session()

During session:                     During session:
  LLM can call save_memory             ObservationLogger auto-logs steps
  (optional, LLM-initiated)            LLM can call save_memory
                                        BudgetEnforcer tracks limits

Session end:                        Session end:
  Layer 1: User clicks "Close"         Budget exhausted
  Layer 2: User switches convo          (iterations/time/cost)
  Layer 3: 30 min idle timeout
  Layer 4: Logout
  Layer 5: 24h GC sweep

Episode promotion:                  Episode promotion:
  Promotion.close_session_with_        Promotion.close_session_with_
    summary() → Tier 3                   summary() → Tier 3
  Stop working memory server           Stop working memory server

Both produce Tier 3 episode summaries that inform future sessions.
```

#### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| SL1 | GenServer idle timeout for Layer 3 | Zero overhead — no polling, no cron. Built-in BEAM mechanism. Every message resets the timer automatically. |
| SL2 | 30 min default idle timeout | Long enough for users who pause to think. Short enough to catch forgotten sessions within the same working period. Configurable per-agent. |
| SL3 | 60s debounce on conversation switch | Prevents rapid switching from triggering multiple LLM calls. User can switch back within 60s without losing the session. |
| SL4 | Promotion requires >= 2 messages | Don't waste an LLM call summarizing a conversation with only a system message. Only promote if there was actual interaction. |
| SL5 | Promotion runs in Task.start (fire and forget) | Don't block the LiveView process or GenServer termination waiting for LLM response. Summary is best-effort. |
| SL6 | 24h GC sweep as safety net | Catches everything else. Long enough that no active session gets accidentally promoted. |

#### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/memory/session_gc.ex` | Periodic GC for orphaned working memory sessions (Layer 5) |
| Modify | `lib/agent_ex/memory/working_memory/server.ex` | Add idle timeout (Layer 3), `last_activity` tracking |
| Modify | `lib/agent_ex_web/live/chat_live.ex` | Layer 1 (close button), Layer 2 (conversation switch promotion with debounce) |
| Modify | `lib/agent_ex_web/user_auth.ex` | Layer 4 (promote active sessions on logout) |
| Modify | `lib/agent_ex/memory/working_memory/supervisor.ex` | Add `list_sessions/1`, `list_all_sessions/0` for GC |
| Modify | `lib/agent_ex/application.ex` | Add SessionGC to supervision tree |

### Delayed Reward System (Multi-Timescale Feedback)

#### The Problem: Not All Outcomes Are Immediate

The autonomous RL loop (Phase 8-F) assumes tool results arrive within the same
session. This works for immediate-feedback tasks:

| Task | Feedback Time | Works Today? |
|---|---|---|
| ML model training | Seconds–minutes | Yes (tool blocks until result) |
| Code testing | Seconds | Yes |
| Stock price prediction | Seconds–minutes | Yes |
| API performance check | Seconds | Yes |

But many real-world tasks have **delayed outcomes**:

| Task | Feedback Time | Works Today? |
|---|---|---|
| Marketing campaign | Days–weeks (sales attribution) | **No** |
| SEO optimization | Days (ranking changes) | **No** |
| A/B testing | Days (statistical significance) | **No** |
| Content strategy | Days–weeks (engagement metrics) | **No** |
| Infrastructure changes | Weeks (reliability metrics) | **No** |
| Drug discovery | Weeks (lab results) | **No** |

The agent launches an action, but the reward signal arrives long after the
session has ended. There is no mechanism to "check back later" and associate
the delayed result with the original decision.

#### Solution: Three-Layer Timescale Architecture

Three GenServer layers that coordinate through the existing memory system:

```text
┌─────────────────────────────────────────────────────────────────┐
│               Meta-Cognitive Layer (RewardEvaluator)             │
│  Timescale: days/weeks                                           │
│  - Wakes on scheduled timers (Process.send_after)               │
│  - Evaluates long-horizon outcomes against original goals        │
│  - Performs retroactive credit assignment to past decisions      │
│  - Calibrates proxy reward models from ground truth              │
│  - Writes evaluated outcomes to Tier 2/3                        │
├─────────────────────────────────────────────────────────────────┤
│               Deliberative Layer (OutcomeManager)                │
│  Timescale: minutes/hours                                        │
│  - Tracks pending outcomes with scheduled check times            │
│  - Routes incoming webhook rewards to correct action records     │
│  - Computes proxy estimates from early signals                   │
│  - Notifies agent when significant outcomes arrive               │
├─────────────────────────────────────────────────────────────────┤
│               Reactive Layer (existing ToolCallerLoop)           │
│  Timescale: seconds/minutes                                      │
│  - Executes immediate tasks, gets immediate feedback             │
│  - Stores actions with IDs for later evaluation                  │
│  - Calls schedule_outcome_check tool for delayed tasks           │
│  - ObservationLogger captures step-level rewards                 │
└─────────────────────────────────────────────────────────────────┘
         │                  │                    │
    ┌────▼──────────────────▼────────────────────▼────┐
    │          Shared Memory (3-Tier + KG)             │
    │  Tier 2: action records, pending outcomes,       │
    │          proxy calibrations, strategy prefs       │
    │  Tier 3: evaluated outcomes (searchable)          │
    │  KG: action → outcome entity relationships        │
    └──────────────────────────────────────────────────┘
```

**Coordination is memory-mediated** — layers do not call each other directly.
The reactive layer writes action records to Tier 2. The deliberative layer reads
them and schedules checks. The meta-cognitive layer evaluates and writes results
back. `ContextBuilder` injects everything into the agent's next session. No
coupling between layers.

#### How Delayed Rewards Flow

##### Day 0: Agent Takes Action

```text
Agent (ToolCallerLoop) calls:
  1. launch_campaign(target: "25-34", budget: 5000, channel: "instagram")
  2. save_memory("Launched campaign-123 targeting 25-34, $5k budget")
  3. schedule_outcome_check(
       action_id: "campaign-123",
       check_at: [+1day, +3days, +7days, +14days],
       metrics: ["impressions", "clicks", "conversions", "revenue"],
       goal: "ROAS > 2.0"
     )
```

`schedule_outcome_check` is a new tool that stores a pending outcome in Tier 2:

```elixir
# Tier 2 key: "pending:campaign-123"
%{
  action_id: "campaign-123",
  agent_id: "marketer",
  action: %{tool: "launch_campaign", args: %{target: "25-34", budget: 5000}},
  goal: "ROAS > 2.0",
  scheduled_checks: [~U[2026-03-29], ~U[2026-03-31], ~U[2026-04-04], ~U[2026-04-11]],
  proxy_estimates: [],
  actual_outcomes: [],
  status: :pending,
  created_at: ~U[2026-03-28]
}
```

The `OutcomeManager` GenServer picks this up and sets timers via
`Process.send_after` for each check time.

##### Day 1: Early Signal (Proxy Reward)

`RewardEvaluator` wakes at the scheduled time:

```text
1. Queries analytics (via tool or webhook data):
   impressions: 50,000, CTR: 2.1%

2. Computes proxy estimate:
   "CTR of 2.1% in first 24h → estimated 1.8% conversion (r=0.72)"
   proxy_reward: 0.65 (moderate confidence)

3. Stores to memory:
   Tier 2: pending:campaign-123 updated with proxy_estimates: [%{day: 1, proxy: 0.65}]
   Tier 3: "Campaign-123 day 1: 50k impressions, 2.1% CTR, proxy ROAS ~1.8"
```

##### Day 7: Statistical Significance

```text
1. Actual conversion data: 1.9%, revenue: $8,200
   Enough data for confident estimate

2. Proxy calibration update:
   Tier 2: proxy_calibration:ctr_to_conversion correlation updated (0.72 → 0.74)

3. Retroactive credit assignment:
   Tier 3: "Campaign-123 interim: 1.9% conversion, $8.2k revenue on $5k spend.
            Targeting 25-34 on Instagram appears effective. On track for ROAS ~2.4"
```

##### Day 14: Ground Truth

```text
1. Full sales attribution: ROAS 2.48, revenue: $12,400

2. Final evaluation:
   Tier 2: outcome:campaign-123 = %{roas: 2.48, revenue: 12400, goal_met: true}
   Tier 2: pending:campaign-123 status → :resolved
   Tier 3: "Campaign-123 FINAL: ROAS 2.48 (goal was 2.0). Instagram + 25-34 targeting
            at $5k budget achieved $12.4k revenue. Key factors: visual-heavy creative,
            weekend launch timing. Recommend repeating with increased budget."
   KG: (campaign-123) --[achieved]--> (ROAS 2.48)
       (campaign-123) --[targeted]--> (demographic: 25-34)
       (instagram) --[effective_for]--> (demographic: 25-34)

3. Proxy calibration:
   Day-1 proxy estimated 0.65 → actual normalized 0.82 → calibration entry updated
```

##### Next Session: Agent Uses Delayed Feedback

```text
ContextBuilder.build("marketer", "new-session") injects:

  Tier 2 (facts):
    "campaign-123 ROAS: 2.48 (goal: 2.0, met)"
    "Instagram effective for 25-34 demographic"

  Tier 3 (semantic search for "plan new campaign"):
    "Campaign-123 achieved 2.48 ROAS on Instagram targeting 25-34.
     Weekend launch timing was a key factor."

  KG (entities):
    "instagram --[effective_for]--> 25-34"

Agent THINKS: "Previous Instagram campaign for 25-34 achieved 2.48 ROAS.
               Let me try the same demographic on TikTok to compare channels."
```

#### Three Reward Delivery Mechanisms

| Mechanism | How | Best For |
|---|---|---|
| **Scheduled polling** | `OutcomeManager` fires timers via `Process.send_after`, queries data source | Regular check intervals (campaign metrics, A/B test results) |
| **Webhook delivery** | Phoenix endpoint receives external event, routes to `OutcomeManager` | Event-driven systems (CI/CD, lab LIMS, payment processors) |
| **Proxy estimation** | Early signals predict final outcome with confidence interval | When partial data arrives early (CTR → conversion, open rate → engagement) |

All three write to the same Tier 2/3 memory, so `ContextBuilder` picks them up
regardless of delivery mechanism.

##### Webhook Endpoint

```elixir
defmodule AgentExWeb.OutcomeWebhookController do
  @moduledoc """
  Receives outcome data from external systems. Routes to OutcomeManager
  which associates the data with the original action and updates memory.
  """
  use AgentExWeb, :controller

  def create(conn, %{"action_id" => action_id, "metrics" => metrics}) do
    case OutcomeManager.deliver_outcome(action_id, metrics) do
      :ok -> json(conn, %{status: "accepted"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "unknown action_id"})
    end
  end
end
```

#### Proxy Rewards: When and How

Proxy rewards provide immediate (approximate) feedback while waiting for ground
truth. The agent uses them to make decisions, but knows they are uncertain.

**When proxy rewards are reliable:**

| Early Signal (Day 1) | Final Outcome (Day 14+) | Correlation | Reliable? |
|---|---|---|---|
| Email open rate | Click-through rate | r > 0.8 | Yes |
| Ad CTR | Conversion rate | r ~ 0.5–0.7 | Moderate |
| Test pass rate | Production stability | r > 0.8 | Yes (if tests are good) |
| User signup rate | 30-day retention | r ~ 0.2–0.4 | **No** |

**Calibration:** The meta-cognitive layer maintains a calibration record per
proxy relationship in Tier 2:

```elixir
# Tier 2 key: "proxy_cal:ctr_to_conversion"
%{
  pairs: [{2.1, 1.8}, {3.0, 2.2}, {1.5, 1.1}],  # historical (proxy, actual)
  correlation: 0.72,
  sample_size: 47,
  last_updated: ~U[2026-03-15],
  drift_detected: false
}
```

When ground truth arrives, the calibration is updated. If correlation drops
below a threshold, the agent is warned: "Proxy estimate for CTR→conversion
may be unreliable (drift detected, r dropped from 0.72 to 0.45)."

**Goodhart's Law guard:** The agent is instructed via system prompt to never
optimize directly for proxy metrics. The proxy is context, not a target.

#### Retroactive Credit Assignment

When a delayed outcome arrives, it needs to be associated with the original
action — not just stored as a standalone fact. The `RewardEvaluator` performs
this by:

1. Looking up `pending:{action_id}` in Tier 2 to find the original action
2. Writing `outcome:{action_id}` with the result + evaluation
3. Updating Tier 3 with a summary that **explicitly links** action and outcome:
   "Agent decided to [action] on [date] because [reasoning]. Result after
   [N days]: [outcome]. This [met/missed] the goal of [goal]."
4. Updating the Knowledge Graph with entity relationships:
   `(action) --[produced]--> (outcome)`

This explicit linking is critical — without it, the LLM sees isolated facts
and cannot perform credit assignment. With it, `ContextBuilder` surfaces
"here's what happened when you made this decision" which directly informs
future reasoning.

#### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| DR1 | Three-layer timescale with memory-mediated coordination | Layers don't call each other. All coordination through Tier 2/3. Decoupled, testable, each layer can fail independently. |
| DR2 | `schedule_outcome_check` as a regular tool | The agent decides when to check back — it knows the domain. Not a hardcoded interval. The LLM reasons about check timing based on the task. |
| DR3 | Both polling and webhook delivery | Polling for scheduled checks, webhooks for event-driven. Same Tier 2/3 storage. `ContextBuilder` doesn't care which delivered the data. |
| DR4 | Proxy rewards with calibration tracking | Provides early signal while waiting. Calibration record detects drift. Agent sees confidence level, not just the estimate. |
| DR5 | Explicit action→outcome linking in Tier 3 | Without explicit links, LLM sees isolated facts. With links, it sees "you did X, result was Y." Credit assignment requires causal narrative. |
| DR6 | `Process.send_after` for scheduled checks | Zero-overhead BEAM timer. Already proven in `PersistentMemory.Store.schedule_sync`. No external cron needed. Survives process restart via DETS pending queue. |
| DR7 | Pending outcomes persisted in DETS | If `OutcomeManager` crashes or server restarts, all pending checks are recovered from DETS on restart. No lost scheduled evaluations. |
| DR8 | Webhook endpoint for external reward delivery | Phoenix already handles HTTP. Minimal new code. External systems (analytics, CI/CD, labs) push data when ready instead of agent polling. |
| DR9 | Goodhart's Law guard via system prompt | Proxy metrics are context, not targets. The agent is instructed to use them for estimation, not optimization. Prevents reward hacking on early signals. |

#### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/reward/outcome_manager.ex` | Deliberative layer: tracks pending outcomes, routes webhooks, schedules checks |
| Create | `lib/agent_ex/reward/reward_evaluator.ex` | Meta-cognitive layer: evaluates delayed outcomes, calibrates proxies, credit assignment |
| Create | `lib/agent_ex/reward/proxy_model.ex` | Proxy reward estimation with calibration tracking |
| Create | `lib/agent_ex/reward/outcome_check_tool.ex` | `schedule_outcome_check` tool for agents to register pending outcomes |
| Create | `lib/agent_ex_web/controllers/outcome_webhook_controller.ex` | Phoenix endpoint for external reward delivery |
| Modify | `lib/agent_ex/memory/context_builder.ex` | Surface recently-resolved outcomes with action→outcome linking |
| Modify | `lib/agent_ex_web/router.ex` | Add `/webhook/outcome/:action_id` route |
| Modify | `lib/agent_ex/application.ex` | Add OutcomeManager + RewardEvaluator to supervision tree |

#### Implementation Order

```text
8-G: Delayed Reward System
  │
  ├─ OutcomeManager GenServer (pending outcomes, scheduled checks, DETS persistence)
  ├─ schedule_outcome_check tool (agent-callable, writes pending records)
  ├─ RewardEvaluator GenServer (periodic evaluation, credit assignment)
  ├─ ProxyModel (estimation + calibration tracking)
  ├─ OutcomeWebhookController (external reward delivery endpoint)
  ├─ ContextBuilder integration (surface resolved outcomes with action links)
  └─ KnowledgeGraph integration (action → outcome entity relationships)
```

### How It Works

#### Connection Flow

```text
1. User generates bridge token in AgentEx UI
   └─ /bridge → [Generate Token] → shows token once (like GitHub PAT)
   └─ Token is scoped: {user_id, allowed_agent_ids, 24h TTL}
   └─ Token stored hashed in DB (never plaintext on server)

2. User sets up bridge on their machine
   └─ $ mkdir -p ~/.agentex
   └─ $ echo "TOKEN_HERE" > ~/.agentex/token && chmod 600 ~/.agentex/token
   └─ $ ./agent_ex_bridge --server wss://agentex.example.com
   └─ Bridge reads token from ~/.agentex/token (not CLI arg)
   └─ Bridge reads policy from ~/.agentex/policy.json (if exists)
   └─ Connects to Phoenix Channel "bridge:{opaque_id}" over WSS
   └─ Server binds token to machine fingerprint on first connect

3. Agent needs to execute a tool
   └─ Intervention pipeline runs (Gate 1)
   └─ Server sandbox validation runs (Gate 2)
   └─ Server pushes HMAC-signed tool_call to bridge via Channel
   └─ Bridge verifies HMAC signature
   └─ Bridge checks local policy (Gate 3)
   └─ Bridge prompts user for write confirmation (Gate 4)
   └─ Bridge executes locally, scrubs secrets, truncates result
   └─ Bridge sends HMAC-signed tool_result back

4. Bridge handles failures gracefully
   └─ Network drop → exponential backoff reconnect with jitter
   └─ Server timeout → pending calls auto-reject after 30s
   └─ Bridge crash → supervisor restarts, reconnects, no data loss
```

#### Bridge Local Policy File

The user's machine has the final say. `~/.agentex/policy.json`:

```json
{
  "allowed_tools": ["shell.run_command", "filesystem.read_file", "filesystem.list_dir"],
  "blocked_tools": ["filesystem.write_file"],
  "allowed_paths": ["/home/user/projects", "/tmp"],
  "blocked_paths": ["/home/user/.ssh", "/home/user/.aws"],
  "blocked_commands": ["rm", "mv", "dd", "kill", "shutdown"],
  "blocked_argument_patterns": ["-rf", "--force.*--recursive", "/dev/sd"],
  "auto_approve_reads": true,
  "max_concurrent_calls": 5,
  "max_result_size_bytes": 1048576
}
```

If `policy.json` doesn't exist, bridge uses safe defaults:
- All tools allowed except `filesystem.write_file`
- All paths allowed except `~/.ssh`, `~/.aws`, `~/.gnupg`
- Common destructive commands blocked
- Write confirmation always on
- Max 5 concurrent calls

#### WebSocket Transport for MCP

Extends the existing `MCP.Transport` behaviour with a secure WebSocket adapter:

```elixir
defmodule AgentEx.MCP.Transport.Channel do
  @moduledoc """
  MCP transport over Phoenix Channels with HMAC message signing.
  Tool calls are sent as Channel pushes, results come back as replies.
  """
  @behaviour AgentEx.MCP.Transport

  @impl true
  def send_request(%{channel_pid: pid, session_key: key} = state, request) do
    ref = make_ref()
    signed = sign_message(request, key)
    send(pid, {:bridge_call, ref, signed})

    receive do
      {:bridge_result, ^ref, result} ->
        case verify_and_sanitize(result, key, state.max_result_size) do
          {:ok, clean} -> {:ok, clean, state}
          {:error, reason} -> {:error, reason, state}
        end
    after
      state.timeout -> {:error, :timeout, state}
    end
  end

  defp sign_message(msg, key) do
    payload = Jason.encode!(msg)
    mac = :crypto.mac(:hmac, :sha256, key, payload)
    %{payload: payload, hmac: Base.encode64(mac)}
  end

  defp verify_and_sanitize(result, key, max_size) do
    with :ok <- verify_hmac(result, key),
         {:ok, decoded} <- Jason.decode(result.payload),
         {:ok, truncated} <- enforce_size_limit(decoded, max_size),
         clean <- scrub_secrets(truncated) do
      {:ok, clean}
    end
  end
end
```

#### Bridge Process (User's Machine)

```elixir
defmodule AgentEx.Bridge do
  @moduledoc """
  Lightweight agent that runs on the user's machine. Connects to the
  AgentEx server via WSS and executes tool calls locally.

  Token is read from ~/.agentex/token (never passed as CLI arg).
  Local policy from ~/.agentex/policy.json overrides server config.

  Distributed as a single binary (Burrito-packaged, no Elixir required).
  """
  use Slipstream

  alias AgentEx.Bridge.{Executor, Policy, Confirmation, SecretScrubber}

  @token_path "~/.agentex/token"
  @policy_path "~/.agentex/policy.json"
  @reconnect_base_ms 1_000
  @reconnect_max_ms 60_000

  def start_link(opts) do
    server = Keyword.fetch!(opts, :server)

    unless String.starts_with?(server, "wss://") do
      raise "Bridge requires WSS (TLS). Refusing to connect over plaintext ws://"
    end

    token = read_token!()
    policy = Policy.load(@policy_path)

    Slipstream.start_link(__MODULE__, %{
      server: server,
      token: token,
      policy: policy,
      session_key: nil,
      reconnect_delay: @reconnect_base_ms
    })
  end

  @impl true
  def handle_join("bridge:" <> _id, %{"session_key" => key}, state) do
    IO.puts("[Bridge] Connected. Policy: #{Policy.summary(state.policy)}")
    {:ok, %{state | session_key: key, reconnect_delay: @reconnect_base_ms}}
  end

  @impl true
  def handle_message("bridge:" <> _, "tool_call", signed_payload, state) do
    with {:ok, payload} <- verify_hmac(signed_payload, state.session_key),
         {:ok, _} <- Policy.check(state.policy, payload),
         {:ok, _} <- Confirmation.maybe_confirm(payload) do

      result = Executor.execute(payload, state.policy)
      scrubbed = SecretScrubber.scrub(result)
      truncated = enforce_size_limit(scrubbed, state.policy.max_result_size_bytes)
      signed = sign_message(truncated, state.session_key)

      push(state.socket, state.topic, "tool_result", %{
        call_id: payload["call_id"],
        result: signed
      })
    else
      {:rejected, reason} ->
        push(state.socket, state.topic, "tool_result", %{
          call_id: payload["call_id"],
          result: sign_message(%{"error" => reason}, state.session_key)
        })
    end

    {:ok, state}
  end

  @impl true
  def handle_disconnect(_reason, state) do
    jitter = :rand.uniform(div(state.reconnect_delay * 30, 100))
    delay = state.reconnect_delay + jitter
    IO.puts("[Bridge] Disconnected. Reconnecting in #{delay}ms...")
    next_delay = min(state.reconnect_delay * 2, @reconnect_max_ms)
    Process.sleep(delay)
    {:reconnect, %{state | reconnect_delay: next_delay}}
  end

  defp read_token! do
    path = Path.expand(@token_path)

    case File.read(path) do
      {:ok, token} ->
        String.trim(token)

      {:error, _} ->
        raise """
        Bridge token not found at #{path}
        Generate a token in AgentEx UI (/bridge) and save it:
          echo "YOUR_TOKEN" > #{path} && chmod 600 #{path}
        """
    end
  end
end
```

#### Server-Side Bridge Channel

```elixir
defmodule AgentExWeb.BridgeChannel do
  @moduledoc """
  Server-side Phoenix Channel for bridge connections.
  Enforces WSS, validates tokens, derives session keys,
  and routes tool calls with HMAC signing.
  """
  use Phoenix.Channel

  alias AgentEx.Bridge.{Registry, Token}

  @max_pending_calls 20

  @impl true
  def join("bridge:" <> _topic, %{"token" => raw_token}, socket) do
    with {:ok, claims} <- Token.verify(raw_token),
         :ok <- Token.check_fingerprint(claims, socket),
         :ok <- Registry.check_not_duplicate(claims.user_id) do

      session_key = :crypto.strong_rand_bytes(32)
      Registry.register(claims.user_id, self(), claims.agent_scope)

      {:ok, %{"session_key" => Base.encode64(session_key)},
       socket
       |> assign(:user_id, claims.user_id)
       |> assign(:session_key, session_key)
       |> assign(:agent_scope, claims.agent_scope)
       |> assign(:pending_count, 0)}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("tool_result", %{"call_id" => call_id, "result" => signed}, socket) do
    case verify_hmac(signed, socket.assigns.session_key) do
      {:ok, result} ->
        sanitized = sanitize_result(result)
        Registry.deliver_result(call_id, sanitized)
        {:noreply, update(socket, :pending_count, &max(&1 - 1, 0))}

      :error ->
        {:noreply, socket}
    end
  end

  @doc "Called by BridgeRegistry when an agent needs to execute a tool."
  def push_tool_call(channel_pid, call_id, tool, args, sandbox, session_key) do
    payload = %{call_id: call_id, tool: tool, args: args, sandbox: sandbox}
    signed = sign_message(payload, session_key)
    send(channel_pid, {:push, "tool_call", signed})
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:user_id] do
      Registry.unregister(socket.assigns.user_id)
    end
    :ok
  end

  defp sanitize_result(result) do
    result
    |> enforce_size_limit(1_048_576)
    |> scrub_xss_payloads()
  end
end
```

#### Bridge Registry

```elixir
defmodule AgentEx.Bridge.Registry do
  @moduledoc """
  Tracks active bridge connections with O(1) ETS lookup.
  Routes tool calls to the correct bridge. Manages pending calls
  with automatic cleanup on timeout or disconnect.
  """
  use GenServer

  @pending_cleanup_interval_ms 10_000

  def online?(user_id), do: :ets.lookup(__MODULE__, user_id) != []

  def register(user_id, channel_pid, agent_scope) do
    ref = Process.monitor(channel_pid)
    :ets.insert(__MODULE__, {user_id, channel_pid, ref, agent_scope})
  end

  def check_not_duplicate(user_id) do
    case :ets.lookup(__MODULE__, user_id) do
      [] -> :ok
      [{_, pid, _, _}] ->
        if Process.alive?(pid), do: {:error, "bridge_already_connected"}, else: :ok
    end
  end

  def unregister(user_id) do
    # Clean up pending calls for this user
    cleanup_pending_for_user(user_id)
    :ets.delete(__MODULE__, user_id)
  end

  def call_tool(user_id, agent_id, tool_call, sandbox, timeout \\ 30_000) do
    case :ets.lookup(__MODULE__, user_id) do
      [] ->
        {:error, :bridge_offline}

      [{_, channel_pid, _, agent_scope}] ->
        unless agent_id in agent_scope or agent_scope == :all do
          {:error, :agent_not_in_scope}
        end

        if pending_count(user_id) >= 20 do
          {:error, :too_many_pending}
        else
          do_call(user_id, channel_pid, tool_call, sandbox, timeout)
        end
    end
  end

  defp do_call(user_id, channel_pid, tool_call, sandbox, timeout) do
    call_id = Base.encode64(:crypto.strong_rand_bytes(16))
    caller = self()
    :ets.insert(:bridge_pending, {call_id, caller, user_id, System.monotonic_time(:millisecond)})

    BridgeChannel.push_tool_call(channel_pid, call_id, tool_call.name, tool_call.arguments, sandbox, session_key)

    receive do
      {:bridge_result, ^call_id, result} ->
        :ets.delete(:bridge_pending, call_id)
        {:ok, result}
    after
      timeout ->
        :ets.delete(:bridge_pending, call_id)
        {:error, :timeout}
    end
  end

  # Periodic sweep of stale pending calls (runs every 10s)
  @impl true
  def handle_info(:cleanup_pending, state) do
    now = System.monotonic_time(:millisecond)
    stale_threshold = now - 60_000

    :ets.select_delete(:bridge_pending, [
      {{:"$1", :"$2", :"$3", :"$4"}, [{:<, :"$4", stale_threshold}], [true]}
    ])

    Process.send_after(self(), :cleanup_pending, @pending_cleanup_interval_ms)
    {:noreply, state}
  end

  # Auto-unregister on bridge process death
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case :ets.match(__MODULE__, {:"$1", :_, ref, :_}) do
      [[user_id]] -> unregister(user_id)
      _ -> :ok
    end
    {:noreply, state}
  end
end
```

### Design Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Bridge is a Burrito-packaged binary | Zero-dependency install. No Elixir/OTP needed. Single file download + run. |
| D2 | Phoenix Channels over WSS | BEAM handles 2M+ concurrent connections. Built-in heartbeat, presence. TLS enforced. |
| D3 | Reuse MCP protocol over Channel transport | Existing `MCP.Client` + `MCP.ToolAdapter` work unchanged. Bridge is just another MCP server. |
| D4 | **Configurable gate defense** | Interactive: 4 gates (intervention → sandbox → policy → confirmation). Autonomous: 3 gates + budget (intervention → sandbox → policy → budget). Mode set per-agent. |
| D5 | Token read from file, not CLI args | CLI args visible in `ps aux`, shell history. File at `~/.agentex/token` with `chmod 600` is standard credential storage. |
| D6 | Token scoped to `{user_id, agent_ids, TTL}` | Leaked token has limited blast radius — only specified agents, expires in 24h, revocable from UI. |
| D7 | Token bound to machine fingerprint | First-use binding (TOFU). Second machine with same token → reject + alert. Prevents token reuse from stolen credentials. |
| D8 | HMAC-signed messages | Session key derived at handshake. Every tool_call and tool_result is HMAC-SHA256 signed. MITM on the WebSocket can't inject or tamper. |
| D9 | Bridge-local policy file | `~/.agentex/policy.json` is the user's override. Server config can restrict further but never loosen what the user blocks. User's machine = user's rules. |
| D10 | Write confirmation prompts (interactive only) | In `:interactive` mode, `:write` tool calls require `y` before executing. In `:autonomous` mode, confirmation is skipped — sandbox + budget are the boundary. |
| D11 | Layered command filtering | Binary denylist + argument pattern filter + full-path resolution + user confirmation. `perl -e 'unlink()'` caught by argument patterns, not just binary name. |
| D12 | Result sanitization pipeline | Size limit (1MB) + secret scrubbing (regex for API keys, tokens, passwords) + XSS scrubbing. Applied on both bridge and server. |
| D13 | Sensitive file denylist | Bridge refuses to read `.env`, `*.pem`, `id_rsa`, `.aws/credentials`, etc. Protects against LLM exfiltrating secrets via tool calls. |
| D14 | Exponential backoff with jitter | Reconnect: 1s → 2s → 4s → ... → 60s cap, ±30% jitter. Prevents reconnect storms when server restarts. |
| D15 | Pending call cleanup | Periodic sweep (10s) of stale pending calls. Process monitors auto-clean on disconnect. No memory leak from unresponsive bridges. |
| D16 | Max concurrent calls per bridge | Capped at 20 pending calls. Prevents compromised server from overwhelming user's machine with rapid tool calls. |
| D17 | Duplicate bridge rejection | Only one bridge per user. Second connection rejected with error. Prevents token sharing / unauthorized parallel access. |
| D18 | Server-side result sanitization | Even after bridge scrubs, server re-sanitizes results. Scrubs XSS payloads before rendering in UI. Defense in depth — don't trust bridge output. |
| D19 | Binary integrity via checksums | Download page shows SHA-256 checksum. Bridge verifies its own integrity on startup (embedded hash). Version check on connect — server warns if outdated. |
| D20 | BEAM clustering for scale | Multiple AgentEx nodes share Registry via `:pg`. Bridge connects to any node; calls route cross-node. |
| D21 | Autonomous mode requires sandbox | UI validates: `execution_mode: :autonomous` cannot be saved without a `root_path`. Prevents accidental unrestricted autonomous agents. |
| D22 | Budget as Gate 4 replacement | `max_iterations`, `max_wall_time_s`, `max_cost_usd` enforce autonomy boundaries. Agent stops gracefully when any limit is reached. |
| D23 | Memory as reward signal | Tier 3 stores experiment outcomes, ContextBuilder injects them into next iteration. In-context RL — LLM improves via richer memory, not weight updates. |
| D24 | Anomaly observer (background) | Monitors tool calls via PubSub. Pauses agent on: repeated failures, resource spikes, out-of-sandbox attempts, budget warnings. Non-blocking. |
| D25 | Two-level reward: step + episode | Step rewards (every SENSE cycle → Tier 2) give fine-grained feedback within a session. Episode rewards (session summary → Tier 3) give strategic guidance across sessions. Both are automatic for autonomous agents. |
| D26 | ObservationLogger hooks into Sensing | Auto-logs structured observations (tool, args, result, delta) after every tool result. Only active for `:autonomous` agents. LLM still has `save_memory` for subjective insights — logger captures objective data. |
| D27 | 5-layer session lifecycle | Explicit close → conversation switch → idle timeout → logout → daily GC. Each layer catches what the one above misses. |
| D28 | GenServer idle timeout (30 min) | Zero-overhead timer built into BEAM. Every message resets it. No polling, no cron. Catches the majority of forgotten sessions. |
| D29 | Conversation switch debounce (60s) | Prevents rapid switching from triggering multiple LLM summary calls. User can switch back within 60s without losing the session. |
| D30 | Promotion requires >= 2 messages | Don't waste an LLM call summarizing a system-only message. Only promote if there was actual interaction. |
| D31 | Promotion runs in Task.start (fire-and-forget) | Don't block LiveView or GenServer termination waiting for LLM. Summary is best-effort — conversation data is already persisted in Postgres. |
| D32 | SessionGC hourly sweep (24h threshold) | Safety net for leaked processes. Long enough that no active session gets accidentally promoted. |
| D33 | Three-layer timescale (reactive/deliberative/meta-cognitive) | Decoupled via memory. Each layer has its own GenServer, own timescale, own failure domain. Coordinate through Tier 2/3 only. |
| D34 | `schedule_outcome_check` as agent-callable tool | Agent knows the domain — it decides when to check back. LLM reasons about check timing ("campaign results take ~14 days"). Not hardcoded. |
| D35 | Both polling + webhook reward delivery | Polling for scheduled checks, webhooks for event-driven. Same Tier 2/3 storage. `ContextBuilder` doesn't care which delivered the data. |
| D36 | Proxy rewards with drift-detecting calibration | Early signals provide fast approximate feedback. Calibration record tracks correlation over time. Agent warned when proxy becomes unreliable. |
| D37 | Explicit action→outcome linking in memory | Without links, LLM sees isolated facts. With links, it sees "you did X, result was Y." Credit assignment requires causal narrative, not just data points. |
| D38 | Pending outcomes persisted in DETS | OutcomeManager crash or server restart → all pending checks recovered from DETS. No lost scheduled evaluations. |

### Scale Properties

```text
Why BEAM/Elixir is uniquely suited for the bridge pattern:

┌─────────────────────────────────────────────────────────────────┐
│ Per-connection overhead                                          │
│   OS thread:    ~50 KB stack + kernel scheduling                │
│   BEAM process: ~2 KB heap  + preemptive fair scheduling        │
│                                                                  │
│ 1 million bridges = ~2 GB RAM (BEAM) vs ~50 GB RAM (threads)   │
├─────────────────────────────────────────────────────────────────┤
│ Message latency                                                  │
│   Server → Bridge: WebSocket frame ≈ network RTT only           │
│   Internal routing: BEAM message pass ≈ microseconds            │
│   Total overhead beyond network: negligible                      │
├─────────────────────────────────────────────────────────────────┤
│ Fault isolation                                                  │
│   One bridge crash → only that user affected                    │
│   One agent crash → supervisor restarts, bridge stays connected │
│   Network partition → bridge reconnects, pending calls timeout  │
├─────────────────────────────────────────────────────────────────┤
│ Horizontal scaling                                               │
│   BEAM nodes cluster natively via Erlang distribution            │
│   BridgeRegistry syncs across nodes via :pg process groups      │
│   Load balancer routes WebSocket to any node                    │
│   Tool calls route cross-node transparently                     │
└─────────────────────────────────────────────────────────────────┘
```

### Files

| Action | File | Purpose |
|---|---|---|
| Create | `lib/agent_ex/bridge/registry.ex` | ETS-based connection registry + pending call routing + periodic cleanup |
| Create | `lib/agent_ex/bridge/token.ex` | Scoped token generation, hashed storage, fingerprint binding, TTL, revocation |
| Create | `lib/agent_ex/bridge/tool_router.ex` | Decides local vs bridge execution, server-side sandbox validation (Gate 2) |
| Create | `lib/agent_ex/bridge/secret_scrubber.ex` | Regex-based secret detection + redaction for tool args and results |
| Create | `lib/agent_ex/bridge/command_filter.ex` | Layered command filter: binary denylist + argument patterns + full-path resolution |
| Create | `lib/agent_ex/mcp/transport/channel.ex` | MCP transport adapter over Phoenix Channels with HMAC signing |
| Create | `lib/agent_ex_web/channels/bridge_channel.ex` | Server-side Channel with HMAC verification + result sanitization |
| Create | `lib/agent_ex_web/channels/bridge_socket.ex` | Socket handler with token auth + WSS enforcement |
| Create | `lib/agent_ex_web/live/bridge_live.ex` | Bridge connection UI (generate token, download, status, revoke) |
| Create | `lib/agent_ex_web/live/bridge_live.html.heex` | Template |
| Create | `lib/agent_ex_web/components/bridge_components.ex` | Status indicator, token display (show-once), download + checksum |
| Create | `lib/agent_ex/bridge_app.ex` | Escript entry point: reads `~/.agentex/token`, enforces WSS |
| Create | `lib/agent_ex/bridge/client.ex` | Bridge-side WebSocket client with backoff + jitter reconnect |
| Create | `lib/agent_ex/bridge/executor.ex` | Bridge-side tool execution with local policy enforcement |
| Create | `lib/agent_ex/bridge/policy.ex` | Parse + apply `~/.agentex/policy.json`, safe defaults |
| Create | `lib/agent_ex/bridge/confirmation.ex` | TTY confirmation prompts for write operations |
| Modify | `lib/agent_ex/application.ex` | Add Bridge.Registry to supervision tree |
| Modify | `lib/agent_ex_web/endpoint.ex` | Add BridgeSocket to endpoint (WSS only) |
| Modify | `lib/agent_ex_web/router.ex` | Add `/bridge` route |
| Modify | `lib/agent_ex_web/components/layouts/app.html.heex` | Bridge status indicator in sidebar |
| Modify | `lib/agent_ex_web/components/agent_components.ex` | Show bridge-required badge on tools |
| Create | `lib/agent_ex/bridge/budget_enforcer.ex` | Tracks iteration count, wall time, token cost per autonomous run |
| Create | `lib/agent_ex/bridge/anomaly_observer.ex` | PubSub-based background monitor, pauses agent on suspicious patterns |
| Create | `lib/agent_ex/bridge/observation_logger.ex` | Auto-logs every tool result as structured step observation for autonomous agents |
| Modify | `lib/agent_ex/agent_config.ex` | Add `execution_mode` (`:interactive` / `:autonomous`) and `budget` fields |
| Modify | `assets/js/app.js` | Bridge presence hook |
| Modify | `mix.exs` | Add `slipstream`, `burrito` |

### Implementation Order

```text
8-A: Security Foundation
  │
  ├─ Bridge.Token (scoped generation, hashed storage, fingerprint binding)
  ├─ Bridge.SecretScrubber (regex patterns for API keys, tokens, passwords)
  ├─ Bridge.CommandFilter (binary denylist + argument patterns + path resolution)
  ├─ Bridge.Policy (parse ~/.agentex/policy.json, safe defaults)
  │
8-B: Bridge Infrastructure
  │
  ├─ Bridge.Registry (ETS + monitors + pending cleanup + duplicate rejection)
  ├─ BridgeChannel + BridgeSocket (WSS enforced, HMAC signed messages)
  ├─ MCP.Transport.Channel (secure WebSocket MCP adapter)
  ├─ Bridge.ToolRouter (local vs bridge dispatch, server sandbox validation)
  │
8-C: Bridge Client (User's Machine)
  │
  ├─ Bridge.Client (WSS connection, token from file, backoff reconnect)
  ├─ Bridge.Executor (local execution with policy + sandbox)
  ├─ Bridge.Confirmation (TTY prompts for write operations)
  ├─ BridgeApp (entry point, WSS enforcement, version check)
  ├─ Burrito packaging (single binary, embedded integrity hash)
  │
8-D: UI + Integration
  │
  ├─ BridgeLive (token generation, download + checksum, status, revoke)
  ├─ BridgeComponents (status indicator, agent editor integration)
  ├─ Sidebar bridge status (online/offline dot)
  └─ Agent card "requires bridge" badge
  │
8-E: Session Lifecycle & Episode Promotion
  │
  ├─ WorkingMemory.Server: idle timeout (Layer 3, 30 min default)
  ├─ ChatLive: "Close & Summarize" button (Layer 1)
  ├─ ChatLive: conversation switch promotion with 60s debounce (Layer 2)
  ├─ UserAuth: promote active sessions on logout (Layer 4)
  ├─ SessionGC: periodic sweep for orphaned sessions (Layer 5)
  ├─ WorkingMemory.Supervisor: list_sessions/1, list_all_sessions/0
  │
8-F: Autonomous Execution Mode + Reward System
  │
  ├─ AgentConfig: execution_mode + budget fields
  ├─ BudgetEnforcer (iteration/time/cost tracking, graceful stop)
  ├─ AnomalyObserver (PubSub monitor, pause on suspicious patterns)
  ├─ ObservationLogger (auto-log step rewards to Tier 2 after each SENSE)
  ├─ Sensing integration: hook ObservationLogger after step 2 for autonomous
  ├─ Bridge.Confirmation respects execution_mode (skip for autonomous)
  ├─ Auto-promote session summary to Tier 3 on budget exhaustion
  ├─ Agent editor: execution mode toggle + budget inputs
  └─ Validation: autonomous requires sandbox.root_path
  │
8-G: Delayed Reward System
  │
  ├─ OutcomeManager GenServer (pending outcomes, scheduled checks, DETS persistence)
  ├─ schedule_outcome_check tool (agent-callable, writes pending records)
  ├─ RewardEvaluator GenServer (periodic evaluation, credit assignment)
  ├─ ProxyModel (estimation + calibration tracking)
  ├─ OutcomeWebhookController (external reward delivery endpoint)
  ├─ ContextBuilder integration (surface resolved outcomes with action links)
  └─ KnowledgeGraph integration (action → outcome entity relationships)
```

---

## File Manifest

### Summary

| Phase | New | Modified | Total |
|---|---|---|---|
| 1 — ToolPlugin | 6 | 2 | 8 |
| 2 — Memory Promotion | 2 | 1 | 3 |
| 3 — Pipe Orchestration | 2 | 0 | 2 |
| 4 — Phoenix + EventLoop | 19 | 7 | 26 |
| 4b — Timezone + User Scoping | 3 | 8 | 11 |
| 4c — Conversation History | 6 | 3 | 9 |
| 4d — Dashboard Refactor | 0 | 12 | 12 |
| 5 — Agent Builder + Tools | 10 | 4 | 14 |
| 5b — Chat Orchestrator + REST | 8 | 3 | 11 |
| 5c — Workflow Engine | 10 | 5 | 15 |
| 6 — Flow Builder + Triggers | 17 | 4 | 21 |
| 7 — Run View + Memory | 11 | 4 | 15 |
| 8 — Hybrid Bridge | 25 | 14 | 39 |
| **Total** | **119** | **67** | **186** |

### Dependencies

Phases 4 and 4b add hex packages. Phases 1–3 need **zero new dependencies**.
Phase 4b adds `tz` (timezone database). Phase 4c needs **zero new dependencies**
(uses existing Ecto/Postgres). Phase 4d adds `salad_ui` (SaladUI component library)
+ `tailwindcss-animate` (npm). Phase 6 may add `quantum` (cron) and `file_system`
(inotify) hex packages.

### Complete File Tree

```text
lib/agent_ex/
├── tool_plugin.ex                          # Phase 1
├── plugin_registry.ex                      # Phase 1
├── plugins/
│   ├── file_system.ex                      # Phase 1
│   └── shell_exec.ex                       # Phase 1
├── memory/
│   ├── promotion.ex                        # Phase 2
│   └── session_gc.ex                      # Phase 8
├── pipe.ex                                 # Phase 3
├── timezone.ex                             # Phase 4b
├── chat.ex                                 # Phase 4c
├── chat/
│   ├── conversation.ex                     # Phase 4c
│   └── message.ex                          # Phase 4c
├── agent_config.ex                         # Phase 5
├── agent_store.ex                          # Phase 5
├── bridge/
│   ├── registry.ex                        # Phase 8
│   ├── token.ex                           # Phase 8
│   ├── tool_router.ex                     # Phase 8
│   ├── secret_scrubber.ex                 # Phase 8
│   ├── command_filter.ex                  # Phase 8
│   ├── client.ex                          # Phase 8
│   ├── executor.ex                        # Phase 8
│   ├── policy.ex                          # Phase 8
│   └── confirmation.ex                    # Phase 8
├── bridge_app.ex                           # Phase 8
├── reward/
│   ├── outcome_manager.ex                 # Phase 8
│   ├── reward_evaluator.ex                # Phase 8
│   ├── proxy_model.ex                     # Phase 8
│   └── outcome_check_tool.ex             # Phase 8
├── flow_config.ex                          # Phase 6
├── flow_store.ex                           # Phase 6
├── trigger/
│   ├── trigger_manager.ex                  # Phase 6
│   ├── trigger_adapter.ex                  # Phase 6
│   ├── cron_trigger.ex                     # Phase 6
│   ├── webhook_trigger.ex                  # Phase 6
│   ├── pubsub_trigger.ex                   # Phase 6
│   ├── file_trigger.ex                     # Phase 6
│   └── chain_trigger.ex                    # Phase 6
└── event_loop/
    ├── event_loop.ex                       # Phase 4
    ├── event.ex                            # Phase 4
    ├── broadcast_handler.ex                # Phase 4
    ├── run_registry.ex                     # Phase 4
    ├── pipe_runner.ex                      # Phase 4
    └── pipe_event_loop.ex                  # Phase 6

lib/agent_ex_web/
├── agent_ex_web.ex                         # Phase 4
├── endpoint.ex                             # Phase 4
├── router.ex                               # Phase 4
├── telemetry.ex                            # Phase 4
├── controllers/
│   ├── webhook_controller.ex               # Phase 6
│   └── outcome_webhook_controller.ex      # Phase 8
├── components/
│   ├── layouts.ex                          # Phase 4
│   ├── layouts/root.html.heex              # Phase 4
│   ├── layouts/app.html.heex               # Phase 4
│   ├── core_components.ex                  # Phase 4
│   ├── chat_components.ex                  # Phase 4
│   ├── conversation_components.ex          # Phase 4c
│   ├── agent_components.ex                 # Phase 5
│   ├── tool_components.ex                  # Phase 5
│   ├── intervention_components.ex          # Phase 5 (embedded in agent editor)
│   ├── bridge_components.ex               # Phase 8
│   ├── flow_components.ex                  # Phase 6
│   ├── run_components.ex                   # Phase 7
│   └── memory_components.ex               # Phase 7
├── channels/
│   ├── bridge_channel.ex                  # Phase 8
│   └── bridge_socket.ex                   # Phase 8
└── live/
    ├── chat_live.ex                        # Phase 4
    ├── chat_live.html.heex                 # Phase 4
    ├── agents_live.ex                      # Phase 5
    ├── agents_live.html.heex               # Phase 5
    ├── tools_live.ex                       # Phase 5
    ├── tools_live.html.heex                # Phase 5
    ├── bridge_live.ex                      # Phase 8
    ├── bridge_live.html.heex              # Phase 8
    ├── flows_live.ex                       # Phase 6
    ├── flows_live.html.heex                # Phase 6
    ├── execution_live.ex                   # Phase 6
    ├── execution_live.html.heex            # Phase 6
    ├── runs_live.ex                        # Phase 7
    ├── runs_live.html.heex                 # Phase 7
    ├── memory_live.ex                      # Phase 7
    ├── memory_live.html.heex               # Phase 7
    └── memory/
        ├── working_memory_component.ex     # Phase 7
        ├── persistent_memory_component.ex  # Phase 7
        ├── semantic_memory_component.ex    # Phase 7
        └── knowledge_graph_component.ex    # Phase 7

assets/
├── js/app.js                               # Phase 4, Phase 4b (hooks)
├── js/hooks/timezone_detect.js             # Phase 4b
├── js/hooks/sortable.js                    # Phase 5
├── js/hooks/flow_editor.js                 # Phase 6
├── js/hooks/graph_viewer.js                # Phase 7
├── css/app.css                             # Phase 4
└── tailwind.config.js                      # Phase 4

test/
├── agent_ex/chat_test.exs                  # Phase 4c
├── plugin_registry_test.exs                # Phase 1
├── plugins/file_system_test.exs            # Phase 1
├── memory/promotion_test.exs               # Phase 2
└── pipe_test.exs                           # Phase 3
```

### Modified Files

```text
mix.exs                            # Phase 4 (deps), Phase 4b (tz), Phase 6 (quantum, file_system)
.gitignore                         # Phase 4 (assets)
lib/agent_ex/application.ex        # Phase 1 + Phase 4 + Phase 6 (TriggerManager)
lib/agent_ex/workbench.ex          # Phase 1 (batch ops)
lib/agent_ex/memory.ex             # Phase 2 (facade)
lib/agent_ex/tool_caller_loop.ex   # Phase 4 (model_fn)
lib/agent_ex/accounts/user.ex      # Phase 4b (timezone field + changeset)
lib/agent_ex/accounts.ex           # Phase 4b (timezone context functions)
lib/agent_ex_web/live/chat_live.ex # Phase 4b (user-scoped agent_id), Phase 4c (conversation persistence + sidebar)
lib/agent_ex_web/router.ex        # Phase 4c (remove ensure_chat_session, add /chat/:conversation_id)
lib/agent_ex_web/components/chat_components.ex # Phase 4c (sidebar layout)
config/config.exs                  # Phase 4, Phase 4b (time_zone_database)
config/dev.exs                     # Phase 4
config/runtime.exs                 # Phase 4
assets/js/app.js                   # Phase 4b (TimezoneDetect hook)
```

---

## Architecture Diagrams

### Pipes All the Way Down

```text
Level 1: Tool
  input ──▶ Tool.execute ──▶ output

Level 2: Agent
  input ──▶ ToolCallerLoop ──▶ output
            (multi-turn LLM + tools)

Level 3: Linear Pipe
  input ──▶ Agent A ──▶ Agent B ──▶ Agent C ──▶ output

Level 4: Fan-out + Merge
  input ──┬──▶ Agent A ──┐
          └──▶ Agent B ──┘──▶ Merge Agent ──▶ output

Level 5: LLM-Composed (Orchestrator with delegate tools)
  input ──▶ Orchestrator ──▶ output
              │
              │ LLM decides at runtime:
              ├── calls delegate_to_researcher("find data")
              ├── calls delegate_to_analyst("analyze data")  ← parallel
              └── calls delegate_to_writer("write report")
              │
              │ Each delegate runs an isolated ToolCallerLoop
              │ Results flow back as tool responses
              │ Orchestrator consolidates
```

### Memory-Informed Workflow Selection

```text
┌────────────────────────────────────────────────────────┐
│ Session Start                                          │
│                                                        │
│ User: "Analyze AAPL stock"                             │
│           │                                            │
│           ▼                                            │
│ ContextBuilder.build(agent_id, session_id)             │
│   │                                                    │
│   ├── Tier 2: preferences → "prefers detailed reports" │
│   ├── Tier 3: vector search("AAPL stock") →            │
│   │     "Session summary: parallel research with       │
│   │      web + financial analyst worked best"           │
│   │     "Fact: AAPL earnings call is March 28"          │
│   └── KG: "AAPL → company → Apple Inc"                 │
│           │                                            │
│           ▼                                            │
│ Injected as system messages before first LLM call      │
│                                                        │
│ Orchestrator LLM sees all this context + the task      │
│ → decides to fan_out to researcher + analyst            │
│ → then merge and pipe through writer                   │
│ → saves "this workflow produced a good report" to Tier 3│
└────────────────────────────────────────────────────────┘
```

### Orchestration Pattern Comparison

```text
Pattern       │ Module         │ Boundaries    │ Who Decides  │ Use Case
──────────────┼────────────────┼───────────────┼──────────────┼────────────────────
Single Agent  │ ToolCallerLoop │ N/A           │ N/A          │ One agent + tools
Pipe (static) │ Pipe.through   │ Isolated      │ Developer    │ Fixed transformation
Pipe (dynamic)│ Pipe + delegate│ Isolated      │ LLM          │ LLM composes workflow
Fan+Merge     │ Pipe.fan_out   │ Isolated      │ Developer    │ Parallel + consolidation
Swarm         │ Swarm          │ Shared convo  │ LLM          │ Dynamic skill routing
```

### Router Map

```text
/                    → ChatLive / RunsLive   (Phase 4 → Phase 7 refactor)
/agents              → AgentsLive            (Phase 5, interventions embedded in agent editor)
/tools               → ToolsLive             (Phase 5)
/workflows           → WorkflowsLive         (Phase 5c)
/flows               → FlowsLive             (Phase 6)
/execution/:run_id   → ExecutionLive         (Phase 6)
/webhook/:id         → WebhookController     (Phase 6)
/runs                → RunsLive              (Phase 7)
/memory              → MemoryLive            (Phase 7)
/bridge              → BridgeLive            (Phase 8)
```
