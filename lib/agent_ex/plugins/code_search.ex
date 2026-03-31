defmodule AgentEx.Plugins.CodeSearch do
  @moduledoc """
  Built-in plugin for searching files and content within a sandboxed directory.

  Provides glob-based file finding, regex content search, and file metadata.
  All paths are resolved relative to a configured root directory.

  ## Config

  - `"root_path"` — root directory for all search operations (required)
  - `"max_results"` — maximum number of results returned (optional, default: 100)
  - `"max_file_size"` — max file size in bytes to grep through (optional, default: 1_048_576)
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @default_max_results 100
  @default_max_file_size 1_048_576

  @impl true
  def manifest do
    %{
      name: "search",
      version: "1.0.0",
      description: "File finding and content search tools",
      config_schema: [
        {:root_path, :string, "Root directory for search operations"},
        {:max_results, :integer, "Maximum number of results returned", optional: true},
        {:max_file_size, :integer, "Max file size in bytes to grep through", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    root = Map.fetch!(config, "root_path") |> Path.expand()
    max_results = Map.get(config, "max_results", @default_max_results)
    max_file_size = Map.get(config, "max_file_size", @default_max_file_size)

    unless File.dir?(root) do
      raise ArgumentError, "root_path #{root} is not a directory"
    end

    tools = [
      find_files_tool(root, max_results),
      grep_tool(root, max_results, max_file_size),
      file_info_tool(root)
    ]

    {:ok, tools}
  end

  defp find_files_tool(root, max_results) do
    Tool.new(
      name: "find_files",
      description:
        "Find files matching a glob pattern (e.g. '**/*.ex', 'lib/**/*.exs'). " <>
          "Returns file paths relative to sandbox root.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Glob pattern to match files (e.g. '**/*.ex', 'src/**/*.ts')"
          },
          "include_hidden" => %{
            "type" => "boolean",
            "description" => "Include hidden files/directories (default: false)"
          }
        },
        "required" => ["pattern"]
      },
      kind: :read,
      function: fn args ->
        pattern = Map.fetch!(args, "pattern")
        include_hidden = Map.get(args, "include_hidden", false)

        full_pattern = Path.join(root, pattern)
        match_opts = if include_hidden, do: [match_dot: true], else: []

        results =
          Path.wildcard(full_pattern, match_opts)
          |> Enum.filter(&valid_within_root?(&1, root))
          |> Enum.take(max_results)
          |> Enum.map(&Path.relative_to(&1, root))

        case results do
          [] -> {:ok, "No files found matching '#{pattern}'"}
          files -> {:ok, Enum.join(files, "\n")}
        end
      end
    )
  end

  defp grep_tool(root, max_results, max_file_size) do
    Tool.new(
      name: "grep",
      description:
        "Search file contents using a regex pattern. " <>
          "Returns matching lines with file path and line number.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regex pattern to search for"
          },
          "file_pattern" => %{
            "type" => "string",
            "description" => "Glob pattern to filter which files to search (default: '**/*')"
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" => "Case-sensitive matching (default: true)"
          },
          "context_lines" => %{
            "type" => "integer",
            "description" => "Number of context lines before and after match (default: 0)"
          }
        },
        "required" => ["pattern"]
      },
      kind: :read,
      function: fn args ->
        search_pattern = Map.fetch!(args, "pattern")
        file_pattern = Map.get(args, "file_pattern", "**/*")
        case_sensitive = Map.get(args, "case_sensitive", true)
        context_lines = Map.get(args, "context_lines", 0)

        regex_opts = if case_sensitive, do: [], else: [:caseless]

        case Regex.compile(search_pattern, regex_opts) do
          {:ok, regex} ->
            full_glob = Path.join(root, file_pattern)

            results =
              Path.wildcard(full_glob)
              |> Enum.filter(
                &(valid_within_root?(&1, root) and regular_file_under_size?(&1, max_file_size))
              )
              |> Enum.flat_map(&search_file(&1, regex, root, context_lines))
              |> Enum.take(max_results)

            case results do
              [] -> {:ok, "No matches found for '#{search_pattern}'"}
              matches -> {:ok, Enum.join(matches, "\n")}
            end

          {:error, {reason, _}} ->
            {:error, "Invalid regex pattern: #{reason}"}
        end
      end
    )
  end

  defp file_info_tool(root) do
    Tool.new(
      name: "file_info",
      description: "Get metadata about a file: size, type, modification time, and permissions.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path relative to sandbox root"
          }
        },
        "required" => ["path"]
      },
      kind: :read,
      function: fn %{"path" => path} ->
        with {:ok, full_path} <- safe_path(root, path) do
          case File.stat(full_path, time: :posix) do
            {:ok, %File.Stat{} = stat} ->
              info = %{
                "path" => path,
                "size" => stat.size,
                "type" => Atom.to_string(stat.type),
                "mode" => format_mode(stat.mode),
                "modified" => format_timestamp(stat.mtime),
                "created" => format_timestamp(stat.ctime)
              }

              {:ok, Jason.encode!(info, pretty: true)}

            {:error, reason} ->
              {:error, "Cannot stat #{path}: #{reason}"}
          end
        end
      end
    )
  end

  # --- Helpers ---

  defp search_file(file_path, regex, root, context_lines) do
    case File.read(file_path) do
      {:ok, content} ->
        relative = Path.relative_to(file_path, root)
        lines = String.split(content, "\n")
        line_count = length(lines)

        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _num} -> Regex.match?(regex, line) end)
        |> Enum.flat_map(&format_match(&1, lines, line_count, relative, context_lines))

      {:error, _} ->
        []
    end
  end

  defp format_match({_line, num}, lines, line_count, relative, context_lines) do
    start = max(1, num - context_lines)
    stop = min(line_count, num + context_lines)

    context =
      lines
      |> Enum.slice(start - 1, stop - start + 1)
      |> Enum.with_index(start)
      |> Enum.map_join("\n", fn {l, n} ->
        marker = if n == num, do: ">", else: " "
        "#{marker} #{n}: #{l}"
      end)

    ["#{relative}:#{num}:", context, ""]
  end

  defp regular_file_under_size?(path, max_size) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_size -> true
      _ -> false
    end
  end

  defp valid_within_root?(path, root) do
    expanded = Path.expand(path)
    root_prefix = String.trim_trailing(root, "/") <> "/"
    expanded == root or String.starts_with?(expanded, root_prefix)
  end

  defp safe_path(root, relative) do
    joined = Path.join(root, relative)
    expanded = Path.expand(joined)
    root_prefix = String.trim_trailing(root, "/") <> "/"

    if expanded == root or String.starts_with?(expanded, root_prefix) do
      {:ok, expanded}
    else
      {:error, "path traversal attempt: #{relative}"}
    end
  end

  defp format_mode(mode) do
    Integer.to_string(mode, 8)
    |> String.slice(-3, 3)
  end

  defp format_timestamp(posix) when is_integer(posix) do
    DateTime.from_unix!(posix) |> DateTime.to_iso8601()
  end

  defp format_timestamp(_), do: "unknown"
end
