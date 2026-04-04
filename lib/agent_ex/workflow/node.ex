defmodule AgentEx.Workflow.Node do
  @moduledoc """
  A single operator node in a workflow DAG.

  Node types:
  - Data operators: `:json_extract`, `:json_transform`, `:json_filter`, `:json_merge`, `:set`, `:code`
  - Flow control: `:if_branch`, `:switch`, `:split`, `:merge`
  - I/O operators: `:trigger`, `:http_request`, `:tool`, `:agent`, `:output`
  """

  @enforce_keys [:id, :type]
  defstruct [
    :id,
    :type,
    :label,
    config: %{},
    position: %{"x" => 0, "y" => 0}
  ]

  @valid_types ~w(
    trigger http_request json_extract json_transform json_filter json_merge
    set if_branch switch split merge code agent tool output
  )a

  @type node_type ::
          :trigger
          | :http_request
          | :json_extract
          | :json_transform
          | :json_filter
          | :json_merge
          | :set
          | :if_branch
          | :switch
          | :split
          | :merge
          | :code
          | :agent
          | :tool
          | :output

  @type t :: %__MODULE__{
          id: String.t(),
          type: node_type(),
          label: String.t() | nil,
          config: map(),
          position: map()
        }

  def valid_types, do: @valid_types

  @doc "Build a Node from a plain map (e.g. decoded from DETS/JSON)."
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map_get(map, :id),
      type: parse_type(map_get(map, :type)),
      label: map_get(map, :label),
      config: map_get(map, :config) || %{},
      position: map_get(map, :position) || %{"x" => 0, "y" => 0}
    }
  end

  defp parse_type(type) when is_atom(type) and type in @valid_types, do: type

  defp parse_type(type) when is_binary(type) do
    case safe_to_atom(type) do
      {:ok, atom} when atom in @valid_types -> atom
      _ -> raise "invalid node type: #{type}"
    end
  end

  defp parse_type(type), do: raise("invalid node type: #{inspect(type)}")

  defp safe_to_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end

  defp map_get(map, key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, to_string(key))
    end
  end
end
