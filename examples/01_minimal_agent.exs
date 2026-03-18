# Single-Agent Guide — Section 1: Minimal Agent
# Run: mix run examples/01_minimal_agent.exs

alias AgentEx.{Message, ModelClient, Tool, ToolAgent, ToolCallerLoop}

bash_tool = Tool.new(
  name: "bash_exec",
  description: "Execute a bash command and return stdout. Use for system queries.",
  kind: :write,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "command" => %{
        "type" => "string",
        "description" => "The bash command to execute"
      }
    },
    "required" => ["command"]
  },
  function: fn %{"command" => command} ->
    case System.cmd("bash", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "exit code #{code}:\n#{output}"}
    end
  end
)

{:ok, agent} = ToolAgent.start_link(tools: [bash_tool])
client = ModelClient.new(model: "gpt-4o")
# Or: client = ModelClient.anthropic("claude-sonnet-4-6")

messages = [
  Message.system("You are a system administration assistant. Use bash_exec to answer questions about the user's machine."),
  Message.user("What OS am I running and how much disk space is available?")
]

{:ok, generated} = ToolCallerLoop.run(agent, client, messages, [bash_tool])
IO.puts(List.last(generated).content)
