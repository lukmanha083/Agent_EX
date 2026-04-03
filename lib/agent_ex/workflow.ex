defmodule AgentEx.Workflow do
  @moduledoc """
  Workflow definition — a static DAG of typed operator nodes connected by edges.

  Unlike the LLM-driven ToolCallerLoop, workflows execute deterministically:
  data flows through operators in topological order. No LLM calls unless an
  `:agent` node is encountered.

  Maps to n8n/Zapier-style workflow automation — users define pipelines visually
  as node graphs. The chat orchestrator can delegate to a workflow just like it
  delegates to an agent, but the workflow runs at zero token cost.

  Stored in Postgres (not DETS) — workflows are server-side definitions that
  benefit from relational integrity and CASCADE deletes from projects.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias AgentEx.Workflow.{Edge, Node}

  schema "workflows" do
    belongs_to(:project, AgentEx.Projects.Project)

    field(:name, :string)
    field(:description, :string)
    field(:nodes, {:array, :map}, default: [])
    field(:edges, {:array, :map}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          project_id: integer(),
          name: String.t(),
          description: String.t() | nil,
          nodes: [map()],
          edges: [map()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for creating a new workflow."
  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:project_id, :name, :description, :nodes, :edges])
    |> validate_required([:project_id, :name])
    |> encode_nodes_and_edges()
    |> unique_constraint([:project_id, :name])
    |> foreign_key_constraint(:project_id)
  end

  @doc "Changeset for updating an existing workflow."
  def update_changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :nodes, :edges])
    |> validate_required([:name])
    |> encode_nodes_and_edges()
    |> unique_constraint([:project_id, :name])
  end

  @doc "Decode JSONB nodes/edges into structs after loading from DB."
  def decode(%__MODULE__{} = workflow) do
    %{
      workflow
      | nodes: Enum.map(workflow.nodes || [], &Node.from_map/1),
        edges: Enum.map(workflow.edges || [], &Edge.from_map/1)
    }
  end

  # Encode Node/Edge structs back to plain maps for JSONB storage.
  defp encode_nodes_and_edges(changeset) do
    changeset
    |> maybe_encode(:nodes)
    |> maybe_encode(:edges)
  end

  defp maybe_encode(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset
      items when is_list(items) -> put_change(changeset, field, Enum.map(items, &to_map/1))
      _ -> changeset
    end
  end

  defp to_map(%{__struct__: _} = struct), do: Map.from_struct(struct) |> stringify_keys()
  defp to_map(map) when is_map(map), do: stringify_keys(map)

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(%{__struct__: _} = s), do: Map.from_struct(s) |> stringify_keys()
  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v), do: Atom.to_string(v)
  defp stringify_value(v), do: v
end
