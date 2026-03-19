# Single-Agent Guide — Section 2: Multi-Tool Agent
# Run: mix run examples/02_multi_tool_agent.exs

alias AgentEx.{Message, ModelClient, Tool, ToolAgent, ToolCallerLoop}

bash_tool = Tool.new(
  name: "bash_exec",
  description: "Execute a bash command. Use for find, ls, wc, and other system commands.",
  kind: :write,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "command" => %{"type" => "string", "description" => "Bash command to execute"}
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

read_file_tool = Tool.new(
  name: "read_file",
  description: "Read the full contents of a file at the given path.",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Absolute file path"}
    },
    "required" => ["path"]
  },
  function: fn %{"path" => path} ->
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end
)

list_dir_tool = Tool.new(
  name: "list_directory",
  description: "List files and directories at the given path.",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string", "description" => "Directory path"}
    },
    "required" => ["path"]
  },
  function: fn %{"path" => path} ->
    case File.ls(path) do
      {:ok, entries} -> {:ok, Enum.join(entries, "\n")}
      {:error, reason} -> {:error, "Cannot list #{path}: #{reason}"}
    end
  end
)

grep_tool = Tool.new(
  name: "grep_search",
  description: "Search for a pattern in files. Returns matching lines with file paths and line numbers.",
  kind: :read,
  parameters: %{
    "type" => "object",
    "properties" => %{
      "pattern" => %{"type" => "string", "description" => "Search pattern (regex)"},
      "path" => %{"type" => "string", "description" => "Directory or file to search"}
    },
    "required" => ["pattern", "path"]
  },
  function: fn %{"pattern" => pattern, "path" => path} ->
    case System.cmd("grep", ["-rn", pattern, path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, "No matches found"}
      {output, _} -> {:error, output}
    end
  end
)

tools = [bash_tool, read_file_tool, list_dir_tool, grep_tool]

{:ok, agent} = ToolAgent.start_link(tools: tools)
client = ModelClient.anthropic("claude-haiku-4-5-20251001")

messages = [
  Message.system("""
  You are a code analysis assistant. You can search, read, and analyze files.
  Use grep_search to find files, read_file to examine them, and bash_exec for
  other operations. Always explain your findings.
  """),
  Message.user("Find all Elixir files that define a GenServer and tell me what each one does")
]

{:ok, generated} = ToolCallerLoop.run(agent, client, messages, tools)
IO.puts(List.last(generated).content)
