defmodule AgentEx.Memory.SemanticMemory.Memory do
  @moduledoc """
  Ecto schema for Tier 3 semantic memory vectors.
  Each row stores an embedded text with its pgvector embedding,
  scoped to a project and agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "semantic_memories" do
    belongs_to(:project, AgentEx.Projects.Project)
    field(:agent_id, :string)
    field(:content, :string)
    field(:memory_type, :string, default: "general")
    field(:session_id, :string)
    field(:embedding, Pgvector.Ecto.Vector)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:project_id, :agent_id, :content, :memory_type, :session_id, :embedding])
    |> validate_required([:project_id, :agent_id, :content, :embedding])
    |> foreign_key_constraint(:project_id)
  end
end
