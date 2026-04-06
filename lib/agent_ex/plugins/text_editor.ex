defmodule AgentEx.Plugins.TextEditor do
  @moduledoc """
  Built-in plugin for precise text file editing with line-number awareness.

  Complements the FileSystem plugin with structured editing operations that
  LLMs can use reliably: read with line numbers, find-and-replace, insert
  at a specific line, and append.

  All paths are resolved relative to a configured root directory.

  ## Config

  - `"root_path"` — root directory for all operations (required)
  - `"max_read_lines"` — max lines returned by read (optional, default: 2000)
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @default_max_read_lines 2000

  @impl true
  def manifest do
    %{
      name: "editor",
      version: "1.0.0",
      description: "Precise text file editing with line-number awareness",
      config_schema: [
        {:root_path, :string, "Root directory for file operations"},
        {:max_read_lines, :integer, "Max lines returned by read", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    root = Map.fetch!(config, "root_path") |> Path.expand()
    max_read_lines = Map.get(config, "max_read_lines", @default_max_read_lines)

    unless File.dir?(root) do
      raise ArgumentError, "root_path #{root} is not a directory"
    end

    tools = [
      read_tool(root, max_read_lines),
      edit_tool(root),
      insert_tool(root),
      append_tool(root)
    ]

    {:ok, tools}
  end

  defp read_tool(root, max_read_lines) do
    Tool.new(
      name: "read",
      description:
        "Read a file with line numbers. Supports offset and limit for large files. " <>
          "Returns content in 'N: line' format.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path relative to sandbox root"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Start reading from this line number (1-based, default: 1)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to return (default: #{max_read_lines})"
          }
        },
        "required" => ["path"]
      },
      kind: :read,
      function: fn args ->
        path = Map.fetch!(args, "path")
        offset = Map.get(args, "offset", 1) |> max(1)
        limit = Map.get(args, "limit", max_read_lines) |> min(max_read_lines) |> max(1)

        with {:ok, full_path} <- safe_path(root, path) do
          case File.read(full_path) do
            {:ok, content} ->
              lines = String.split(content, "\n")
              total = length(lines)

              numbered =
                lines
                |> Enum.with_index(1)
                |> Enum.drop(offset - 1)
                |> Enum.take(limit)
                |> Enum.map_join("\n", fn {line, num} -> "#{num}\t#{line}" end)

              header = "[#{path}] lines #{offset}-#{min(offset + limit - 1, total)} of #{total}"
              {:ok, header <> "\n" <> numbered}

            {:error, :enoent} ->
              {:error, "File not found: #{path}"}

            {:error, reason} ->
              {:error, "Cannot read #{path}: #{reason}"}
          end
        end
      end
    )
  end

  defp edit_tool(root) do
    Tool.new(
      name: "edit",
      description:
        "Find and replace text in a file. The old_string must match exactly (including " <>
          "indentation). Use replace_all to replace every occurrence, or just the first match.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path relative to sandbox root"
          },
          "old_string" => %{
            "type" => "string",
            "description" =>
              "Exact text to find (must be unique in the file unless replace_all is true)"
          },
          "new_string" => %{
            "type" => "string",
            "description" => "Text to replace it with"
          },
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace all occurrences (default: false)"
          }
        },
        "required" => ["path", "old_string", "new_string"]
      },
      kind: :write,
      function: fn args ->
        path = Map.fetch!(args, "path")
        old_string = Map.fetch!(args, "old_string")
        new_string = Map.fetch!(args, "new_string")
        replace_all = Map.get(args, "replace_all", false)

        if old_string == "" do
          {:error, "old_string cannot be empty"}
        else
          with {:ok, full_path} <- safe_path(root, path),
               {:ok, content} <- read_file_for_edit(full_path, path),
               {:ok, new_content, count} <-
                 do_replace(content, old_string, new_string, replace_all, path) do
            case File.write(full_path, new_content) do
              :ok -> {:ok, "Replaced #{count} occurrence(s) in #{path}"}
              {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
            end
          end
        end
      end
    )
  end

  defp insert_tool(root) do
    Tool.new(
      name: "insert",
      description:
        "Insert text at a specific line number. The new text is inserted before " <>
          "the specified line. Use line 0 to insert at the beginning.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path relative to sandbox root"
          },
          "line" => %{
            "type" => "integer",
            "description" => "Line number to insert before (0 = beginning, -1 = end)"
          },
          "text" => %{
            "type" => "string",
            "description" => "Text to insert"
          }
        },
        "required" => ["path", "line", "text"]
      },
      kind: :write,
      function: fn args ->
        path = Map.fetch!(args, "path")
        line = Map.fetch!(args, "line")
        text = Map.fetch!(args, "text")

        with {:ok, full_path} <- safe_path(root, path),
             {:ok, content} <- read_file_for_edit(full_path, path) do
          lines = String.split(content, "\n")
          insert_at = resolve_insert_position(line, length(lines))
          new_content = lines |> List.insert_at(insert_at, text) |> Enum.join("\n")

          case File.write(full_path, new_content) do
            :ok -> {:ok, "Inserted text at line #{insert_at + 1} in #{path}"}
            {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
          end
        end
      end
    )
  end

  defp append_tool(root) do
    Tool.new(
      name: "append",
      description: "Append text to the end of a file. Creates the file if it doesn't exist.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path relative to sandbox root"
          },
          "text" => %{
            "type" => "string",
            "description" => "Text to append"
          }
        },
        "required" => ["path", "text"]
      },
      kind: :write,
      function: fn args ->
        path = Map.fetch!(args, "path")
        text = Map.fetch!(args, "text")

        with {:ok, full_path} <- safe_path(root, path),
             :ok <- File.mkdir_p(Path.dirname(full_path)) do
          case File.open(full_path, [:append, :utf8]) do
            {:ok, file} ->
              result = IO.write(file, text)
              File.close(file)

              case result do
                :ok -> {:ok, "Appended to #{path}"}
                {:error, reason} -> {:error, "Write failed for #{path}: #{reason}"}
              end

            {:error, reason} ->
              {:error, "Cannot append to #{path}: #{reason}"}
          end
        end
      end
    )
  end

  # --- Helpers ---

  defp safe_path(root, relative) do
    if String.starts_with?(relative, "/") do
      {:error, "absolute paths not allowed, use a path relative to sandbox root: #{relative}"}
    else
      joined = Path.join(root, relative)
      expanded = Path.expand(joined)
      root_prefix = String.trim_trailing(root, "/") <> "/"

      cond do
        not (expanded == root or String.starts_with?(expanded, root_prefix)) ->
          {:error, "path traversal attempt: #{relative}"}

        contains_symlink?(expanded, root) ->
          {:error, "symlinks not allowed in sandbox: #{relative}"}

        true ->
          {:ok, expanded}
      end
    end
  end

  defp contains_symlink?(path, root) do
    relative = Path.relative_to(path, root)

    Path.split(relative)
    |> Enum.scan(root, fn part, acc -> Path.join(acc, part) end)
    |> Enum.any?(fn component ->
      case File.lstat(component) do
        {:ok, %File.Stat{type: :symlink}} -> true
        _ -> false
      end
    end)
  end

  defp read_file_for_edit(full_path, display_path) do
    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{display_path}"}
      {:error, reason} -> {:error, "Cannot read #{display_path}: #{reason}"}
    end
  end

  defp do_replace(content, old_string, new_string, replace_all, path) do
    occurrences = count_occurrences(content, old_string)

    cond do
      occurrences == 0 ->
        {:error, "old_string not found in #{path}"}

      occurrences > 1 and not replace_all ->
        {:error,
         "old_string has #{occurrences} occurrences in #{path}. " <>
           "Use replace_all: true or provide more context to make it unique."}

      replace_all ->
        {:ok, String.replace(content, old_string, new_string), occurrences}

      true ->
        {:ok, replace_first(content, old_string, new_string), 1}
    end
  end

  defp resolve_insert_position(line, total) do
    cond do
      line == -1 -> total
      line <= 0 -> 0
      line > total -> total
      true -> line - 1
    end
  end

  defp count_occurrences(string, substring) do
    parts = String.split(string, substring)
    length(parts) - 1
  end

  defp replace_first(string, old, new) do
    case String.split(string, old, parts: 2) do
      [before, rest] -> before <> new <> rest
      [_no_match] -> string
    end
  end
end
