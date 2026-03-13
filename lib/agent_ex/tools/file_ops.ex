defmodule AgentEx.Tools.FileOps do
  @moduledoc """
  Local file operations tool — read, write, and list files.

  Path-restricted to a configurable base directory to prevent traversal.
  Works with any model via standard tool calling.
  """

  alias AgentEx.Tool

  @doc "Returns a Tool struct for file operations."
  def tool(opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    Tool.new(
      name: "file_ops",
      description: "Read, write, or list files within the allowed directory.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "operation" => %{
            "type" => "string",
            "enum" => ["read", "write", "list"],
            "description" => "File operation to perform"
          },
          "path" => %{
            "type" => "string",
            "description" => "Relative file path"
          },
          "content" => %{
            "type" => "string",
            "description" => "Content to write (for write operation)"
          }
        },
        "required" => ["operation", "path"]
      },
      function: fn args -> execute(args, base_dir) end
    )
  end

  defp execute(%{"operation" => "read", "path" => path}, base_dir) do
    with {:ok, full_path} <- resolve_path(path, base_dir) do
      File.read(full_path)
    end
  end

  defp execute(%{"operation" => "write", "path" => path, "content" => content}, base_dir) do
    with {:ok, full_path} <- resolve_path(path, base_dir) do
      full_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(full_path, content)
      {:ok, "Written #{byte_size(content)} bytes to #{path}"}
    end
  end

  defp execute(%{"operation" => "list", "path" => path}, base_dir) do
    with {:ok, full_path} <- resolve_path(path, base_dir) do
      case File.ls(full_path) do
        {:ok, entries} -> {:ok, Enum.join(entries, "\n")}
        {:error, reason} -> {:error, "Cannot list: #{reason}"}
      end
    end
  end

  defp resolve_path(path, base_dir) do
    full = Path.expand(path, base_dir)
    expanded_base = Path.expand(base_dir)

    if String.starts_with?(full, expanded_base) do
      {:ok, full}
    else
      {:error, "Path traversal blocked: '#{path}' resolves outside allowed directory"}
    end
  end
end
