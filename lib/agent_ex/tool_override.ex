defmodule AgentEx.ToolOverride do
  @moduledoc """
  Wrap a tool with overridden metadata without modifying the original.

  Maps to AutoGen's `ToolOverride` wrapper class. The LLM sees the override
  name/description; intervention checks the original kind.

  ## Example

      tool = Tool.new(name: "search_db", description: "Search database", ...)
      renamed = ToolOverride.rename(tool, "find_records")
      renamed.name  #=> "find_records"
      renamed.kind  #=> :read  (preserved from original)
  """

  alias AgentEx.Tool

  @doc """
  Wrap an existing tool with metadata overrides.

  Supported override keys: `:name`, `:description`, `:parameters`.
  The `:kind` and `:function` are always preserved from the original.
  The original name is stored in the closure for traceability.
  """
  @spec wrap(Tool.t(), keyword()) :: Tool.t()
  def wrap(%Tool{} = tool, overrides) when is_list(overrides) do
    original_name = tool.name
    original_fn = tool.function

    wrapped_fn = fn args ->
      original_fn.(args)
    end

    %Tool{
      name: Keyword.get(overrides, :name, tool.name),
      description: Keyword.get(overrides, :description, tool.description),
      parameters: Keyword.get(overrides, :parameters, tool.parameters),
      function: wrapped_fn,
      kind: tool.kind,
      type: tool.type
    }
    |> put_original_name(original_name)
  end

  @doc "Rename a tool while preserving everything else."
  @spec rename(Tool.t(), String.t()) :: Tool.t()
  def rename(%Tool{} = tool, new_name) when is_binary(new_name) do
    wrap(tool, name: new_name)
  end

  @doc "Change a tool's description while preserving everything else."
  @spec redescribe(Tool.t(), String.t()) :: Tool.t()
  def redescribe(%Tool{} = tool, new_desc) when is_binary(new_desc) do
    wrap(tool, description: new_desc)
  end

  @doc "Get the original name of a wrapped tool, or nil if not wrapped."
  @spec original_name(Tool.t()) :: String.t() | nil
  def original_name(%Tool{} = tool) do
    Process.get({__MODULE__, :original_name, tool.name})
  end

  # Store original name in process dictionary keyed by the new tool name.
  # This avoids modifying the Tool struct while keeping traceability.
  defp put_original_name(%Tool{name: new_name} = tool, original_name) do
    Process.put({__MODULE__, :original_name, new_name}, original_name)
    tool
  end
end
