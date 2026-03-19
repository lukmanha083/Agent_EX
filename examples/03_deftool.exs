# Single-Agent Guide — Section 3: Tool Definition with deftool
# Run: mix run examples/03_deftool.exs

defmodule ComputerTools do
  import AgentEx.ToolBuilder

  deftool :bash_exec, "Execute a bash command and return stdout", kind: :write do
    param :command, :string, "The bash command to execute"
  end

  def bash_exec(%{"command" => command}) do
    case System.cmd("bash", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "exit code #{code}:\n#{output}"}
    end
  end

  deftool :read_file, "Read the full contents of a file" do
    param :path, :string, "Absolute file path"
  end

  def read_file(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end
end

alias AgentEx.{Message, ModelClient, ToolAgent, ToolCallerLoop}

tools = [ComputerTools.bash_exec_tool(), ComputerTools.read_file_tool()]
{:ok, agent} = ToolAgent.start_link(tools: tools)
client = ModelClient.anthropic("claude-sonnet-4-20250514")

messages = [
  Message.system("You are a helpful assistant."),
  Message.user("What Elixir version is installed?")
]

{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools)
IO.puts(List.last(generated).content)

