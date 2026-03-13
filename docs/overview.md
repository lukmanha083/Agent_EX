# AgentEx — Overview

AgentEx is an Elixir/OTP reimplementation of the core patterns found in
[Microsoft AutoGen](https://github.com/microsoft/autogen), a Python framework
for building multi-agent AI systems.

## Why Elixir?

AutoGen's Python implementation builds an **actor model on top of asyncio** —
agents send messages to each other, run tool calls concurrently, and coordinate
through a runtime. These are patterns that Elixir and the BEAM VM provide as
**first-class primitives**.

| What AutoGen builds manually | What BEAM gives you natively |
|---|---|
| Agent message routing via `AgentRuntime` | Built-in process message passing |
| `asyncio.gather()` for parallel tool calls | `Task.async_stream` with true OS-level parallelism |
| `CancellationToken` for cancellation | Process monitors, links, and `Task.shutdown` |
| Exception wrapping in `ToolException` | Process isolation — one crash doesn't affect others |
| `InterventionHandler` middleware | Message interception in GenServer callbacks |
| Agent registry via `AgentId` | `Registry` module with unique/duplicate key modes |
| Restart logic on failure | OTP Supervisors with automatic restart strategies |

## Core Concept: The Sense-Think-Act Loop

The central pattern in both AutoGen and AgentEx is the **tool-calling loop** — an
iterative Sense-Think-Act cycle between an LLM and a tool executor:

```
User Question
     │
     ▼
┌──────────────────────────────────────────────────────┐
│              Sense-Think-Act Loop                     │
│                                                      │
│  THINK ─▶ LLM decides what info it needs             │
│     │                                                │
│     ▼                                                │
│  SENSE ─▶ Intervention check + tools (parallel)      │
│     │     ┌──────────────────────────────────┐       │
│     │     │  intervene → dispatch →          │       │
│     │     │  process → feed_back             │       │
│     │     └──────────────────────────────────┘       │
│     ▼                                                │
│  THINK ─▶ LLM reasons about observations             │
│     │                                                │
│     ├── needs more info? ──▶ loop back to SENSE      │
│     └── ready to answer? ──▶ ACT (exit loop)         │
└──────────────────────────────────────────────────────┘
     │
     ▼
Answer to User
```

1. **THINK** — The LLM receives the question plus available tools, decides what to do
2. **SENSE** — If the LLM needs information, it returns `FunctionCall` objects.
   The `Sensing` module runs them through the intervention pipeline (permission
   checks), dispatches approved calls in parallel, and feeds observations back
3. **THINK** — The LLM sees the observations and decides: sense more or respond?
4. **ACT** — When the LLM has enough information, it returns a text response

## Module Map

```
AgentEx
├── Message             — Message types (system, user, assistant, tool)
│   ├── FunctionCall       — LLM's request to invoke a tool
│   └── FunctionResult     — Result of executing a tool (observation)
├── Tool                — Tool definition with :kind (:read/:write)
├── ToolAgent           — GenServer that holds and executes registered tools
├── Sensing             — Sensing phase: intervene → dispatch → process → feed back
├── Intervention        — Behaviour + pipeline for gating tool calls
│   ├── PermissionHandler  — Block all :write tools (chmod 444)
│   ├── WriteGateHandler   — Allow specific :write tools (chmod +w)
│   └── LogHandler         — Audit log, always approves
├── ToolCallerLoop      — Sense-Think-Act orchestration loop (single agent)
├── Handoff             — HandoffMessage + transfer tool generation
│   └── HandoffMessage     — Conversation transfer between agents
├── Swarm               — Multi-agent orchestration via handoffs
│   └── Agent              — Swarm participant (name, system_message, tools, handoffs)
├── ModelClient         — HTTP client for OpenAI-compatible LLM APIs
├── Application         — OTP supervisor tree + Registry
└── Example             — Working usage example with permissions
```

## Quick Start

```elixir
# 1. Define tools with :kind (like Linux file permissions)
read_tool = AgentEx.Tool.new(
  name: "get_weather",
  description: "Get weather for a city",
  kind: :read,                       # r-- (sensing, auto-approved)
  parameters: %{
    "type" => "object",
    "properties" => %{"city" => %{"type" => "string"}},
    "required" => ["city"]
  },
  function: fn %{"city" => city} -> {:ok, "Sunny in #{city}"} end
)

write_tool = AgentEx.Tool.new(
  name: "send_email",
  description: "Send an email",
  kind: :write,                      # rw- (acting, can be gated)
  parameters: %{
    "type" => "object",
    "properties" => %{"to" => %{"type" => "string"}, "body" => %{"type" => "string"}},
    "required" => ["to", "body"]
  },
  function: fn %{"to" => to} -> {:ok, "Sent to #{to}"} end
)

tools = [read_tool, write_tool]

# 2. Start the ToolAgent (GenServer)
{:ok, tool_agent} = AgentEx.ToolAgent.start_link(tools: tools)

# 3. Create the LLM client
client = AgentEx.ModelClient.new(model: "gpt-4o")

# 4. Build messages
messages = [
  AgentEx.Message.system("You are helpful. Use tools when needed."),
  AgentEx.Message.user("What's the weather in Tokyo? Email it to bob@example.com")
]

# 5. Run with intervention — only allow send_email to write
gate = AgentEx.Intervention.WriteGateHandler.new(allowed_writes: ["send_email"])

{:ok, generated} = AgentEx.ToolCallerLoop.run(
  tool_agent, client, messages, tools,
  intervention: [AgentEx.Intervention.LogHandler, gate]
)

IO.puts(List.last(generated).content)
```

## Multi-Agent Quick Start (Swarm)

```elixir
alias AgentEx.{Handoff, Message, ModelClient, Swarm}

# 1. Define agents with handoff targets
planner = Swarm.Agent.new(
  name: "planner",
  system_message: "You route tasks to specialists. Transfer to analyst for data work.",
  handoffs: ["analyst", "user"]
)

analyst = Swarm.Agent.new(
  name: "analyst",
  system_message: "You analyze financial data using tools.",
  tools: [stock_tool],          # Regular tools
  handoffs: ["planner", "user"] # Can hand back to planner or to user (terminates)
)

# 2. Create the LLM client
client = ModelClient.new(model: "gpt-4o")

# 3. Run the swarm — stops when any agent hands off to "user"
{:ok, generated, handoff} = Swarm.run(
  [planner, analyst], client,
  [Message.user("Analyze AAPL stock")],
  start: "planner",
  termination: {:handoff, "user"}
)

# handoff is %HandoffMessage{target: "user", source: "analyst"}
# Resume later: send a new message back to the agent that handed off
```
