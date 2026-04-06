defmodule AgentEx.Repo.Migrations.CreateSemanticMemoriesAndKnowledgeGraph do
  use Ecto.Migration

  def change do
    # --- Tier 3: Semantic Memory ---

    create table(:semantic_memories) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :agent_id, :string, null: false
      add :content, :text, null: false
      add :memory_type, :string, default: "general"
      add :session_id, :string
      add :embedding, :vector, size: 1536, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:semantic_memories, [:project_id, :agent_id])

    execute(
      "CREATE INDEX semantic_memories_embedding_idx ON semantic_memories USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS semantic_memories_embedding_idx"
    )

    # --- Knowledge Graph: Entities (shared, not project-scoped) ---

    create table(:kg_entities) do
      add :name, :string, null: false
      add :entity_type, :string, null: false
      add :description, :text
      add :summary, :text
      add :name_embedding, :vector, size: 1536

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:kg_entities, [:name, :entity_type])

    execute(
      "CREATE INDEX kg_entities_embedding_idx ON kg_entities USING hnsw (name_embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS kg_entities_embedding_idx"
    )

    # --- Knowledge Graph: Episodes (per-project, per-agent) ---

    create table(:kg_episodes) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :agent_id, :string, null: false
      add :content, :text, null: false
      add :role, :string
      add :source, :string
      add :content_embedding, :vector, size: 1536

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:kg_episodes, [:project_id, :agent_id])

    execute(
      "CREATE INDEX kg_episodes_embedding_idx ON kg_episodes USING hnsw (content_embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS kg_episodes_embedding_idx"
    )

    # --- Knowledge Graph: Facts (entity → entity relationships) ---

    create table(:kg_facts) do
      add :source_entity_id, references(:kg_entities, on_delete: :delete_all), null: false
      add :target_entity_id, references(:kg_entities, on_delete: :delete_all), null: false
      add :fact_type, :string, null: false
      add :description, :text, null: false
      add :confidence, :string
      add :description_embedding, :vector, size: 1536

      timestamps(type: :utc_datetime_usec)
    end

    create index(:kg_facts, [:source_entity_id])
    create index(:kg_facts, [:target_entity_id])

    execute(
      "CREATE INDEX kg_facts_embedding_idx ON kg_facts USING hnsw (description_embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS kg_facts_embedding_idx"
    )

    # --- Knowledge Graph: Entity ↔ Episode links ---

    create table(:kg_mentions) do
      add :entity_id, references(:kg_entities, on_delete: :delete_all), null: false
      add :episode_id, references(:kg_episodes, on_delete: :delete_all), null: false
      add :confidence, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:kg_mentions, [:entity_id])
    create index(:kg_mentions, [:episode_id])
    create unique_index(:kg_mentions, [:entity_id, :episode_id])
  end
end
