defmodule AgentEx.Memory.KnowledgeGraph.Mention do
  @moduledoc """
  Ecto schema for entity ↔ episode links.
  Tracks which entities were mentioned in which episodes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "kg_mentions" do
    belongs_to(:entity, AgentEx.Memory.KnowledgeGraph.Entity)
    belongs_to(:episode, AgentEx.Memory.KnowledgeGraph.Episode)
    field(:confidence, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, [:entity_id, :episode_id, :confidence])
    |> validate_required([:entity_id, :episode_id])
    |> unique_constraint([:entity_id, :episode_id])
    |> foreign_key_constraint(:entity_id)
    |> foreign_key_constraint(:episode_id)
  end
end
