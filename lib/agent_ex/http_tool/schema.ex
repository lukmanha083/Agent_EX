defmodule AgentEx.HttpTool.Schema do
  @moduledoc """
  Ecto schema for tool_configs table.
  Maps to/from HttpTool struct for persistence.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "tool_configs" do
    belongs_to(:project, AgentEx.Projects.Project)
    field(:user_id, :integer)
    field(:name, :string)
    field(:description, :string)
    field(:system, :boolean, default: false)

    # HTTP config
    field(:method, :string, default: "GET")
    field(:url_template, :string)
    field(:headers, :map, default: %{})
    field(:parameters, {:array, :map}, default: [])
    field(:response_type, :string)
    field(:response_path, :string)
    field(:kind, :string, default: "read")

    # Capability index
    field(:capability_embedding, Pgvector.Ecto.Vector)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :name]
  @optional_fields [
    :user_id,
    :project_id,
    :description,
    :system,
    :method,
    :url_template,
    :headers,
    :parameters,
    :response_type,
    :response_path,
    :kind,
    :capability_embedding
  ]

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:project_id, :name])
    |> foreign_key_constraint(:project_id)
  end

  @doc "Convert an HttpTool struct to Ecto-compatible attrs map."
  def from_tool(%AgentEx.HttpTool{} = tool) do
    tool
    |> Map.from_struct()
    |> Map.put(:kind, to_string(tool.kind))
  end

  @doc "Convert an Ecto schema row to an HttpTool struct."
  def to_tool(%__MODULE__{} = row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__, :project, :capability_embedding, :system])
    |> Map.update(:kind, :read, &coerce_kind/1)
    |> then(&struct!(AgentEx.HttpTool, &1))
  end

  defp coerce_kind("write"), do: :write
  defp coerce_kind("read"), do: :read
  defp coerce_kind(atom) when is_atom(atom), do: atom
  defp coerce_kind(_), do: :read
end
