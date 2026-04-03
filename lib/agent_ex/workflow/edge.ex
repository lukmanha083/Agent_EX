defmodule AgentEx.Workflow.Edge do
  @moduledoc """
  A directed connection between two nodes in a workflow DAG.

  `source_port` identifies which output port of the source node to connect from
  (e.g. "output", "true", "false", "case_1"). `target_port` is always "input".
  """

  @enforce_keys [:id, :source_node_id, :target_node_id]
  defstruct [
    :id,
    :source_node_id,
    :target_node_id,
    source_port: "output",
    target_port: "input"
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source_node_id: String.t(),
          target_node_id: String.t(),
          source_port: String.t(),
          target_port: String.t()
        }

  @doc "Build an Edge from a plain map."
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map_get(map, :id),
      source_node_id: map_get(map, :source_node_id),
      target_node_id: map_get(map, :target_node_id),
      source_port: map_get(map, :source_port) || "output",
      target_port: map_get(map, :target_port) || "input"
    }
  end

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end
end
