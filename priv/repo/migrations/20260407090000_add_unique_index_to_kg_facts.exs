defmodule AgentEx.Repo.Migrations.AddUniqueIndexToKgFacts do
  use Ecto.Migration

  def change do
    create unique_index(:kg_facts, [:source_entity_id, :target_entity_id, :fact_type])
  end
end
