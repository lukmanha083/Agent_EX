defmodule AgentEx.Plugins.FileSystem do
  @moduledoc """
  Built-in plugin for sandboxed file operations.

  All paths are resolved relative to a configured root directory.
  Write operations are disabled by default.

  ## Config

  - `"root_path"` — root directory for all operations (required)
  - `"allow_write"` — enable write operations (optional, default: false)
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @impl true
  def manifest do
    %{
      name: "filesystem",
      version: "1.0.0",
      description: "Sandboxed file operations",
      config_schema: [
        {:root_path, :string, "Root directory for file operations"},
        {:allow_write, :boolean, "Enable write operations", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    root = Map.fetch!(config, "root_path")
    root = Path.expand(root)
    allow_write = Map.get(config, "allow_write", false)

    unless File.dir?(root) do
      raise ArgumentError, "root_path #{root} is not a directory"
    end

    tools = [read_file_tool(root), list_dir_tool(root)]
    tools = if allow_write, do: tools ++ [write_file_tool(root)], else: tools
    {:ok, tools}
  end

  defp read_file_tool(root) do
    Tool.new(
      name: "read_file",
      description: "Read the contents of a file (relative to sandbox root)",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path relative to root"}
        },
        "required" => ["path"]
      },
      kind: :read,
      function: fn %{"path" => path} ->
        full_path = safe_path(root, path)

        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
        end
      end
    )
  end

  defp list_dir_tool(root) do
    Tool.new(
      name: "list_dir",
      description: "List files and directories (relative to sandbox root)",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Directory path relative to root (default: .)"
          }
        },
        "required" => []
      },
      kind: :read,
      function: fn args ->
        dir_path = safe_path(root, Map.get(args, "path", "."))

        case File.ls(dir_path) do
          {:ok, entries} -> {:ok, Enum.join(entries, "\n")}
          {:error, reason} -> {:error, "Cannot list directory: #{reason}"}
        end
      end
    )
  end

  defp write_file_tool(root) do
    Tool.new(
      name: "write_file",
      description: "Write content to a file (relative to sandbox root)",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path relative to root"},
          "content" => %{"type" => "string", "description" => "Content to write"}
        },
        "required" => ["path", "content"]
      },
      kind: :write,
      function: fn %{"path" => path, "content" => content} ->
        full_path = safe_path(root, path)
        dir = Path.dirname(full_path)
        File.mkdir_p!(dir)

        case File.write(full_path, content) do
          :ok -> {:ok, "Written to #{path}"}
          {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
        end
      end
    )
  end

  defp safe_path(root, relative) do
    joined = Path.join(root, relative)
    expanded = Path.expand(joined)

    unless String.starts_with?(expanded, root) do
      raise ArgumentError, "path traversal attempt: #{relative}"
    end

    expanded
  end
end
