# Phases 1-3 Integration Test — Plugins, Memory Promotion, and Pipes
# Run: mix run examples/04_pipe_and_plugins.exs

alias AgentEx.{Memory, ModelClient, Pipe, PluginRegistry, Tool, Workbench}

client = ModelClient.anthropic("claude-haiku-4-5-20251001")

IO.puts("=" |> String.duplicate(60))
IO.puts("Phase 1 — ToolPlugin: FileSystem plugin")
IO.puts("=" |> String.duplicate(60))

{:ok, wb} = Workbench.start_link()
{:ok, reg} = PluginRegistry.start_link(workbench: wb)

:ok = PluginRegistry.attach(reg, AgentEx.Plugins.FileSystem, %{
  "root_path" => Path.expand("lib/agent_ex", __DIR__ |> Path.dirname()),
  "allow_write" => false
})

plugins = PluginRegistry.list_attached(reg)
IO.puts("Attached plugins: #{Enum.map(plugins, & &1.name) |> Enum.join(", ")}")

tools = Workbench.list_tools(wb)
IO.puts("Registered tools: #{Enum.map(tools, & &1.name) |> Enum.join(", ")}")

# Use a plugin tool directly
result = Workbench.call_tool(wb, "filesystem.list_dir", %{})
IO.puts("\nfilesystem.list_dir (root):\n#{result.content}\n")

result = Workbench.call_tool(wb, "filesystem.read_file", %{"path" => "tool.ex"})
IO.puts("filesystem.read_file (tool.ex): #{String.slice(result.content, 0, 100)}...\n")

IO.puts("=" |> String.duplicate(60))
IO.puts("Phase 2 — Memory Promotion: save_memory tool")
IO.puts("=" |> String.duplicate(60))

save_tool = Memory.save_memory_tool(agent_id: "test_agent")
IO.puts("Tool name: #{save_tool.name}")
IO.puts("Tool kind: #{save_tool.kind}")
IO.puts("Parameters: #{inspect(save_tool.parameters["properties"] |> Map.keys())}\n")

IO.puts("=" |> String.duplicate(60))
IO.puts("Phase 3 — Pipe: Static pipeline with real LLM")
IO.puts("=" |> String.duplicate(60))

# Two-stage pipeline: researcher → writer
researcher = Pipe.Agent.new(
  name: "researcher",
  system_message: """
  You are a concise research assistant. When given a topic, provide 3 key facts about it.
  Be brief — one sentence per fact.
  """
)

writer = Pipe.Agent.new(
  name: "writer",
  system_message: """
  You are a concise writer. Take the research input and write a single short paragraph
  summarizing the key points. Keep it under 50 words.
  """
)

IO.puts("\nRunning: 'Elixir OTP' |> researcher |> writer\n")

result =
  "Elixir OTP"
  |> Pipe.through(researcher, client)
  |> Pipe.through(writer, client)

IO.puts("Pipeline result:\n#{result}\n")

IO.puts("=" |> String.duplicate(60))
IO.puts("Phase 3 — Pipe: Agent with tools")
IO.puts("=" |> String.duplicate(60))

# Agent that uses a tool
calc_tool = Tool.new(
  name: "multiply",
  description: "Multiply two numbers",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "a" => %{"type" => "number", "description" => "First number"},
      "b" => %{"type" => "number", "description" => "Second number"}
    },
    "required" => ["a", "b"]
  },
  function: fn %{"a" => a, "b" => b} -> {:ok, "#{a * b}"} end
)

math_agent = Pipe.Agent.new(
  name: "math_agent",
  system_message: "You are a math assistant. Use the multiply tool to compute products. State the final answer clearly.",
  tools: [calc_tool]
)

IO.puts("\nRunning: math_agent with multiply tool\n")
result = Pipe.through("What is 17 times 23?", math_agent, client)
IO.puts("Result: #{result}\n")

IO.puts("=" |> String.duplicate(60))
IO.puts("Phase 3 — Pipe: Fan-out + Merge")
IO.puts("=" |> String.duplicate(60))

optimist = Pipe.Agent.new(
  name: "optimist",
  system_message: "You see the bright side of everything. Give one optimistic sentence about the topic."
)

pessimist = Pipe.Agent.new(
  name: "pessimist",
  system_message: "You see risks and downsides. Give one cautionary sentence about the topic."
)

consolidator = Pipe.Agent.new(
  name: "consolidator",
  system_message: "Combine the two perspectives into a single balanced sentence of under 30 words."
)

IO.puts("\nRunning: 'AI coding assistants' |> fan_out([optimist, pessimist]) |> merge(consolidator)\n")

result =
  "AI coding assistants"
  |> Pipe.fan_out([optimist, pessimist], client)
  |> Pipe.merge(consolidator, client)

IO.puts("Balanced result: #{result}\n")

IO.puts("=" |> String.duplicate(60))
IO.puts("Phase 3 — Pipe: Delegate tool (LLM-composed workflow)")
IO.puts("=" |> String.duplicate(60))

fact_checker = Pipe.Agent.new(
  name: "fact_checker",
  system_message: "You verify claims. Given a statement, say whether it's true or false in one sentence."
)

delegate = Pipe.delegate_tool("fact_checker", fact_checker, client)

orchestrator = Pipe.Agent.new(
  name: "orchestrator",
  system_message: """
  You coordinate work. When asked to verify a claim, delegate it to the fact_checker.
  After getting the result, state the conclusion in your own words.
  """,
  tools: [delegate]
)

IO.puts("\nRunning: orchestrator delegates to fact_checker\n")
result = Pipe.through("Is Elixir built on the Erlang VM?", orchestrator, client)
IO.puts("Orchestrator result: #{result}\n")

IO.puts("=" |> String.duplicate(60))
IO.puts("All phases tested successfully!")
IO.puts("=" |> String.duplicate(60))
