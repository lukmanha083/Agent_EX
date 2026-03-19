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
        with {:ok, binary, args} <- parse_command(command),
             :ok <- check_allowed(binary, allowed) do
          execute_command(binary, args, timeout, working_dir)
        end
      end
    )
  end

  defp parse_command(command) do
    case String.split(String.trim(command)) do
      [binary | args] -> {:ok, binary, args}
      [] -> {:error, "Empty command"}
    end
  end

  defp check_allowed(binary, allowed) do
    if binary in allowed,
      do: :ok,
      else: {:error, "Command '#{binary}' not allowed. Permitted: #{Enum.join(allowed, ", ")}"}
  end

  defp execute_command(binary, args, timeout, working_dir) do
    opts = [stderr_to_stdout: true]
    opts = if working_dir, do: [{:cd, working_dir} | opts], else: opts

    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(binary, args, opts)}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} -> {:ok, output}
      {:ok, {:ok, {output, code}}} -> {:error, "Command exited with code #{code}: #{output}"}
      {:ok, {:error, reason}} -> {:error, "Command failed: #{reason}"}
      nil -> {:error, "Command timed out after #{timeout}ms"}
    end
  end
end
