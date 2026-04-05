defmodule AgentEx.Plugins.Diff do
  @moduledoc """
  Built-in plugin for comparing files and text.

  Provides unified diff output for comparing two files or two text strings.
  Uses Elixir's built-in `List.myers_difference/2` for pure-Elixir line-level diffing.

  ## Config

  - `"root_path"` — root directory for file operations (required)
  - `"context_lines"` — number of context lines in diff output (optional, default: 3)
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool

  @default_context_lines 3

  @impl true
  def manifest do
    %{
      name: "diff",
      version: "1.0.0",
      description: "File and text comparison tools",
      config_schema: [
        {:root_path, :string, "Root directory for file operations"},
        {:context_lines, :integer, "Number of context lines in diff output", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    root = Map.fetch!(config, "root_path") |> Path.expand()
    context_lines = Map.get(config, "context_lines", @default_context_lines)

    unless File.dir?(root) do
      raise ArgumentError, "root_path #{root} is not a directory"
    end

    tools = [
      compare_files_tool(root, context_lines),
      compare_text_tool(context_lines)
    ]

    {:ok, tools}
  end

  defp compare_files_tool(root, context_lines) do
    Tool.new(
      name: "compare_files",
      description:
        "Compare two files and show differences in unified diff format. " <>
          "Paths are relative to sandbox root.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_a" => %{
            "type" => "string",
            "description" => "First file path (relative to root)"
          },
          "file_b" => %{
            "type" => "string",
            "description" => "Second file path (relative to root)"
          },
          "context" => %{
            "type" => "integer",
            "description" => "Number of context lines (default: #{context_lines})"
          }
        },
        "required" => ["file_a", "file_b"]
      },
      kind: :read,
      function: fn args ->
        file_a = Map.fetch!(args, "file_a")
        file_b = Map.fetch!(args, "file_b")
        ctx = Map.get(args, "context", context_lines)

        with {:ok, path_a} <- safe_path(root, file_a),
             {:ok, path_b} <- safe_path(root, file_b),
             {:ok, content_a} <- read_file(path_a, file_a),
             {:ok, content_b} <- read_file(path_b, file_b) do
          diff = unified_diff(content_a, content_b, file_a, file_b, ctx)

          if diff == "" do
            {:ok, "Files are identical"}
          else
            {:ok, diff}
          end
        end
      end
    )
  end

  defp compare_text_tool(context_lines) do
    Tool.new(
      name: "compare_text",
      description: "Compare two text strings and show differences in unified diff format.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text_a" => %{
            "type" => "string",
            "description" => "First text to compare"
          },
          "text_b" => %{
            "type" => "string",
            "description" => "Second text to compare"
          },
          "label_a" => %{
            "type" => "string",
            "description" => "Label for first text (default: 'a')"
          },
          "label_b" => %{
            "type" => "string",
            "description" => "Label for second text (default: 'b')"
          },
          "context" => %{
            "type" => "integer",
            "description" => "Number of context lines (default: #{context_lines})"
          }
        },
        "required" => ["text_a", "text_b"]
      },
      kind: :read,
      function: fn args ->
        text_a = Map.fetch!(args, "text_a")
        text_b = Map.fetch!(args, "text_b")
        label_a = Map.get(args, "label_a", "a")
        label_b = Map.get(args, "label_b", "b")
        ctx = Map.get(args, "context", context_lines)

        diff = unified_diff(text_a, text_b, label_a, label_b, ctx)

        if diff == "" do
          {:ok, "Texts are identical"}
        else
          {:ok, diff}
        end
      end
    )
  end

  # --- Unified Diff Implementation ---

  defp unified_diff(text_a, text_b, label_a, label_b, context) do
    lines_a = String.split(text_a, "\n")
    lines_b = String.split(text_b, "\n")

    edits = compute_edit_script(lines_a, lines_b)

    if Enum.all?(edits, fn {op, _} -> op == :eq end) do
      ""
    else
      hunks = group_into_hunks(edits, context)

      header = "--- #{label_a}\n+++ #{label_b}\n"

      body = Enum.map_join(hunks, "\n", &format_hunk/1)

      header <> body
    end
  end

  defp compute_edit_script(lines_a, lines_b) do
    # Line-level diff using List.myers_difference/2
    List.myers_difference(lines_a, lines_b)
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &{:eq, &1})
      {:del, lines} -> Enum.map(lines, &{:del, &1})
      {:ins, lines} -> Enum.map(lines, &{:ins, &1})
    end)
  end

  defp group_into_hunks(edits, context) do
    indexed =
      edits
      |> Enum.with_index()

    # Find ranges of changed lines
    change_indices =
      indexed
      |> Enum.filter(fn {{op, _}, _idx} -> op in [:del, :ins] end)
      |> Enum.map(fn {_, idx} -> idx end)

    case change_indices do
      [] ->
        []

      _ ->
        groups = group_nearby(change_indices, context * 2 + 1)
        Enum.map(groups, &build_hunk(&1, edits, context))
    end
  end

  defp build_hunk({start_idx, end_idx}, edits, context) do
    hunk_start = max(0, start_idx - context)
    hunk_end = min(length(edits) - 1, end_idx + context)
    lines = Enum.slice(edits, hunk_start..hunk_end)

    {a_count, b_count} =
      Enum.reduce(lines, {0, 0}, fn
        {:eq, _}, {a, b} -> {a + 1, b + 1}
        {:del, _}, {a, b} -> {a + 1, b}
        {:ins, _}, {a, b} -> {a, b + 1}
      end)

    prefix = if hunk_start == 0, do: [], else: Enum.slice(edits, 0..(hunk_start - 1))

    %{
      a_start: Enum.count(prefix, fn {op, _} -> op in [:eq, :del] end) + 1,
      a_count: a_count,
      b_start: Enum.count(prefix, fn {op, _} -> op in [:eq, :ins] end) + 1,
      b_count: b_count,
      lines: lines
    }
  end

  defp group_nearby([], _gap), do: []

  defp group_nearby([first | rest], gap) do
    do_group_nearby(rest, first, first, gap)
  end

  defp do_group_nearby([], start, stop, _gap), do: [{start, stop}]

  defp do_group_nearby([idx | rest], start, stop, gap) do
    if idx - stop <= gap do
      do_group_nearby(rest, start, idx, gap)
    else
      [{start, stop} | do_group_nearby(rest, idx, idx, gap)]
    end
  end

  defp format_hunk(%{a_start: as, a_count: ac, b_start: bs, b_count: bc, lines: lines}) do
    header = "@@ -#{as},#{ac} +#{bs},#{bc} @@"

    body =
      Enum.map_join(lines, "\n", fn
        {:eq, text} -> " #{text}"
        {:del, text} -> "-#{text}"
        {:ins, text} -> "+#{text}"
      end)

    header <> "\n" <> body
  end

  # --- Helpers ---

  defp safe_path(root, relative) do
    if String.starts_with?(relative, "/") do
      {:error, "absolute paths not allowed, use a path relative to sandbox root: #{relative}"}
    else
      joined = Path.join(root, relative)
      expanded = Path.expand(joined)
      root_prefix = String.trim_trailing(root, "/") <> "/"

      if expanded == root or String.starts_with?(expanded, root_prefix) do
        {:ok, expanded}
      else
        {:error, "path traversal attempt: #{relative}"}
      end
    end
  end

  defp read_file(full_path, display_path) do
    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{display_path}"}
      {:error, reason} -> {:error, "Cannot read #{display_path}: #{reason}"}
    end
  end
end
