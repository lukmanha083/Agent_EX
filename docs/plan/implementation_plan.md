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

**Status:** Phases 1–4 implemented (2026-03-20). Phase 5+ pending.

**Table of Contents**

1. [Design Philosophy](#design-philosophy)
2. [Phase Dependency Graph](#phase-dependency-graph)
3. [Phase 1 — ToolPlugin Behaviour + Plugin Registry](#phase-1--toolplugin-behaviour--plugin-registry)
4. [Phase 2 — Memory Promotion + Session Context](#phase-2--memory-promotion--session-context)
5. [Phase 3 — Pipe-Based Orchestration](#phase-3--pipe-based-orchestration)
6. [Phase 4 — Phoenix Foundation + EventLoop](#phase-4--phoenix-foundation--eventloop)
7. [Phase 5 — Agent Builder + Unified Tool Management](#phase-5--agent-builder--unified-tool-management)
8. [Phase 6 — Flow Builder + Triggers](#phase-6--flow-builder--triggers)
9. [Phase 7 — Run View + Memory Inspector](#phase-7--run-view--memory-inspector)
10. [File Manifest](#file-manifest)
11. [Architecture Diagrams](#architecture-diagrams)

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
Phase 4 (Phoenix + EventLoop) ──▶ Phase 5 (Agent Builder + Tools)
                                         │
                                         ▼
                                  Phase 6 (Flow Builder + Triggers)
                                         │
                                         ▼
                                  Phase 7 (Run View + Memory Inspector)
```

- Phases 1, 2, and 4 can start in **parallel**.
- Phase 3 depends on Phase 1 (plugin integration) and Phase 2 (save_memory tool).
- Phase 5 depends on Phase 4 (Phoenix infrastructure) + Phase 3 (Pipe agents).
- Phase 6 depends on Phase 5 (agent configs) + Phase 3 (Pipe/Swarm composition).
- Phase 7 depends on Phase 6 (execution model) but can start in parallel for memory parts.

**Recommended order:** 1+2 (parallel) → 3 → 4 → 5 → 6 → 7.

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

## File Manifest

### Summary

| Phase | New | Modified | Total |
|---|---|---|---|
| 1 — ToolPlugin | 6 | 2 | 8 |
| 2 — Memory Promotion | 2 | 1 | 3 |
| 3 — Pipe Orchestration | 2 | 0 | 2 |
| 4 — Phoenix + EventLoop | 19 | 7 | 26 |
| 5 — Agent Builder + Tools | 12 | 4 | 16 |
| 6 — Flow Builder + Triggers | 17 | 4 | 21 |
| 7 — Run View + Memory | 11 | 4 | 15 |
| **Total** | **69** | **22** | **91** |

### Dependencies

Only Phase 4 adds hex packages. Phases 1–3 need **zero new dependencies**.
Phase 6 may add `quantum` (cron) and `file_system` (inotify) hex packages.

### Complete File Tree

```text
lib/agent_ex/
├── tool_plugin.ex                          # Phase 1
├── plugin_registry.ex                      # Phase 1
├── plugins/
│   ├── file_system.ex                      # Phase 1
│   └── shell_exec.ex                       # Phase 1
├── memory/
│   └── promotion.ex                        # Phase 2
├── pipe.ex                                 # Phase 3
├── agent_config.ex                         # Phase 5
├── agent_store.ex                          # Phase 5
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
│   └── webhook_controller.ex               # Phase 6
├── components/
│   ├── layouts.ex                          # Phase 4
│   ├── layouts/root.html.heex              # Phase 4
│   ├── layouts/app.html.heex               # Phase 4
│   ├── core_components.ex                  # Phase 4
│   ├── chat_components.ex                  # Phase 4
│   ├── agent_components.ex                 # Phase 5
│   ├── tool_components.ex                  # Phase 5
│   ├── intervention_components.ex          # Phase 5
│   ├── flow_components.ex                  # Phase 6
│   ├── run_components.ex                   # Phase 7
│   └── memory_components.ex               # Phase 7
└── live/
    ├── chat_live.ex                        # Phase 4
    ├── chat_live.html.heex                 # Phase 4
    ├── agents_live.ex                      # Phase 5
    ├── agents_live.html.heex               # Phase 5
    ├── tools_live.ex                       # Phase 5
    ├── tools_live.html.heex                # Phase 5
    ├── intervention_builder_live.ex        # Phase 5
    ├── intervention_builder_live.html.heex # Phase 5
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
├── js/app.js                               # Phase 4
├── js/hooks/sortable.js                    # Phase 5
├── js/hooks/flow_editor.js                 # Phase 6
├── js/hooks/graph_viewer.js                # Phase 7
├── css/app.css                             # Phase 4
└── tailwind.config.js                      # Phase 4

test/
├── plugin_registry_test.exs                # Phase 1
├── plugins/file_system_test.exs            # Phase 1
├── memory/promotion_test.exs               # Phase 2
└── pipe_test.exs                           # Phase 3
```

### Modified Files

```text
mix.exs                            # Phase 4 (deps), Phase 6 (quantum, file_system)
.gitignore                         # Phase 4 (assets)
lib/agent_ex/application.ex        # Phase 1 + Phase 4 + Phase 6 (TriggerManager)
lib/agent_ex/workbench.ex          # Phase 1 (batch ops)
lib/agent_ex/memory.ex             # Phase 2 (facade)
lib/agent_ex/tool_caller_loop.ex   # Phase 4 (model_fn)
config/config.exs                  # Phase 4
config/dev.exs                     # Phase 4
config/runtime.exs                 # Phase 4
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
/agents              → AgentsLive            (Phase 5)
/tools               → ToolsLive             (Phase 5)
/interventions       → InterventionBuilder   (Phase 5)
/flows               → FlowsLive             (Phase 6)
/execution/:run_id   → ExecutionLive         (Phase 6)
/webhook/:id         → WebhookController     (Phase 6)
/runs                → RunsLive              (Phase 7)
/memory              → MemoryLive            (Phase 7)
```
