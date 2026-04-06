defmodule AgentEx.Memory.KnowledgeGraph.Episode do
  @moduledoc """
  Ecto schema for knowledge graph episodes.
  Episodes are per-project, per-agent conversation turns.
  Deleted automatically via CASCADE when the project is deleted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "kg_episodes" do
    belongs_to(:project, AgentEx.Projects.Project)
    field(:agent_id, :string)
    field(:content, :string)
    field(:role, :string)
    field(:source, :string)
    field(:content_embedding, Pgvector.Ecto.Vector)

    has_many(:mentions, AgentEx.Memory.KnowledgeGraph.Mention)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(episode, attrs) do
    episode
    |> cast(attrs, [:project_id, :agent_id, :content, :role, :source, :content_embedding])
    |> validate_required([:project_id, :agent_id, :content])
    |> foreign_key_constraint(:project_id)
  end
end
