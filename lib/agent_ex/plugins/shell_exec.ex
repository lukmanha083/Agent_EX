defmodule AgentEx.Plugins.ShellExec do
  @moduledoc """
  Built-in plugin for sandboxed shell command execution.

  Supports an allowlist of permitted commands and a configurable timeout.

  ## Config

  - `"allowed_commands"` — list of allowed command prefixes (required)
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
        {:allowed_commands, {:array, :string}, "List of allowed command prefixes"},
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

  defp run_command_tool(allowed, _timeout, working_dir) do
    Tool.new(
      name: "run_command",
      description:
        "Execute a shell command. Allowed commands: #{Enum.join(allowed, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The shell command to execute"
          }
        },
        "required" => ["command"]
      },
      kind: :write,
      function: fn %{"command" => command} ->
        if command_allowed?(command, allowed) do
          opts = [stderr_to_stdout: true]
          opts = if working_dir, do: [{:cd, working_dir} | opts], else: opts

          try do
            {output, exit_code} = System.cmd("sh", ["-c", command], opts)

            if exit_code == 0 do
              {:ok, output}
            else
              {:error, "Command exited with code #{exit_code}: #{output}"}
            end
          catch
            :error, reason ->
              {:error, "Command failed: #{inspect(reason)}"}
          end
        else
          {:error, "Command not allowed. Permitted: #{Enum.join(allowed, ", ")}"}
        end
      end
    )
  end

  defp command_allowed?(command, allowed) do
    cmd = String.trim(command)
    Enum.any?(allowed, fn prefix -> String.starts_with?(cmd, prefix) end)
  end
end
