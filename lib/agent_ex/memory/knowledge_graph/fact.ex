defmodule AgentEx.Memory.KnowledgeGraph.Fact do
  @moduledoc """
  Ecto schema for knowledge graph facts (entity → entity relationships).
  Facts are shared across projects — relationships are universal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "kg_facts" do
    belongs_to(:source_entity, AgentEx.Memory.KnowledgeGraph.Entity)
    belongs_to(:target_entity, AgentEx.Memory.KnowledgeGraph.Entity)
    field(:fact_type, :string)
    field(:description, :string)
    field(:confidence, :string)
    field(:description_embedding, Pgvector.Ecto.Vector)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(fact, attrs) do
    fact
    |> cast(attrs, [
      :source_entity_id,
      :target_entity_id,
      :fact_type,
      :description,
      :confidence,
      :description_embedding
    ])
    |> validate_required([:source_entity_id, :target_entity_id, :fact_type, :description])
    |> foreign_key_constraint(:source_entity_id)
    |> foreign_key_constraint(:target_entity_id)
  end
end
