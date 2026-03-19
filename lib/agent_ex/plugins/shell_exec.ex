defmodule AgentEx.Plugins.ShellExec do
  @moduledoc """
  Built-in plugin for sandboxed shell command execution.

  Supports an allowlist of permitted command binaries and a configurable timeout.
  Commands are executed directly (not via `sh -c`) to prevent shell injection.

  ## Config

  - `"allowed_commands"` — list of allowed command binaries (required)
  - `"timeout"` — execution timeout in ms (optional, default: 10000)
  - `"working_dir"` — working directory for commands (optional)
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @impl true
  def manifest do
    %{
      name: "shell",
      version: "1.0.0",
      description: "Sandboxed shell command execution with allowlist",
      config_schema: [
        {:allowed_commands, {:array, :string}, "List of allowed command binaries"},
        {:timeout, :integer, "Execution timeout in ms", optional: true},
        {:working_dir, :string, "Working directory for commands", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    allowed = Map.fetch!(config, "allowed_commands")
    timeout = Map.get(config, "timeout", 10_000)
    working_dir = Map.get(config, "working_dir")

    tools = [run_command_tool(allowed, timeout, working_dir)]
    {:ok, tools}
  end

  defp run_command_tool(allowed, timeout, working_dir) do
    Tool.new(
      name: "run_command",
      description: "Execute a command. Allowed binaries: #{Enum.join(allowed, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The command to execute (e.g. 'ls -la /tmp')"
          }
        },
        "required" => ["command"]
      },
      kind: :write,
      function: fn %{"command" => command} ->
        case parse_command(command) do
          {binary, args} ->
            if binary in allowed do
              opts = [stderr_to_stdout: true]
              opts = if working_dir, do: [{:cd, working_dir} | opts], else: opts

              task = Task.async(fn -> System.cmd(binary, args, opts) end)

              case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
                {:ok, {output, 0}} ->
                  {:ok, output}

                {:ok, {output, exit_code}} ->
                  {:error, "Command exited with code #{exit_code}: #{output}"}

                nil ->
                  {:error, "Command timed out after #{timeout}ms"}
              end
            else
              {:error, "Command '#{binary}' not allowed. Permitted: #{Enum.join(allowed, ", ")}"}
            end

          :error ->
            {:error, "Empty command"}
        end
      end
    )
  end

  defp parse_command(command) do
    case String.split(String.trim(command)) do
      [binary | args] -> {binary, args}
      [] -> :error
    end
  end
end
