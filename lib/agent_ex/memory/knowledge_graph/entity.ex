defmodule AgentEx.Memory.KnowledgeGraph.Entity do
  @moduledoc """
  Ecto schema for knowledge graph entities.
  Entities are shared across projects and agents — they represent
  world knowledge (people, organizations, concepts, etc.).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "kg_entities" do
    field(:name, :string)
    field(:entity_type, :string)
    field(:description, :string)
    field(:summary, :string)
    field(:name_embedding, Pgvector.Ecto.Vector)

    has_many(:outgoing_facts, AgentEx.Memory.KnowledgeGraph.Fact, foreign_key: :source_entity_id)
    has_many(:incoming_facts, AgentEx.Memory.KnowledgeGraph.Fact, foreign_key: :target_entity_id)
    has_many(:mentions, AgentEx.Memory.KnowledgeGraph.Mention)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [:name, :entity_type, :description, :summary, :name_embedding])
    |> validate_required([:name, :entity_type])
    |> unique_constraint([:name, :entity_type])
  end
end
