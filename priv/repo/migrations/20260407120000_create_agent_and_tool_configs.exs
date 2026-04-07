defmodule AgentEx.Repo.Migrations.CreateAgentAndToolConfigs do
  use Ecto.Migration

  def change do
    # --- Agent Configs (replaces per-project DETS) ---

    create table(:agent_configs, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, on_delete: :delete_all)
      add :user_id, :bigint
      add :name, :string, null: false
      add :description, :text
      add :system, :boolean, default: false, null: false

      # Identity
      add :role, :string
      add :expertise, {:array, :string}, default: []
      add :personality, :string

      # Goal
      add :goal, :text
      add :success_criteria, :text

      # Constraints
      add :constraints, {:array, :string}, default: []
      add :scope, :string

      # Tools
      add :tool_ids, {:array, :string}, default: []
      add :tool_guidance, :text
      add :tool_examples, {:array, :map}, default: []
      add :disabled_builtins, {:array, :string}, default: []

      # Output
      add :output_format, :text
      add :system_prompt, :text

      # Provider/Model
      add :provider, :string, default: "openai"
      add :model, :string, default: "gpt-4o-mini"
      add :context_window, :integer

      # Safety
      add :intervention_pipeline, {:array, :map}, default: []
      add :sandbox, :map, default: %{}
      add :execution_mode, :string, default: "interactive"
      add :budget, :map, default: %{}

      # Capability index for meritocratic agent selection
      add :capability_embedding, :vector, size: 1536

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_configs, [:project_id])
    create index(:agent_configs, [:user_id, :project_id])
    create unique_index(:agent_configs, [:project_id, :name])

    execute(
      "CREATE INDEX agent_configs_capability_idx ON agent_configs USING hnsw (capability_embedding vector_cosine_ops) WHERE capability_embedding IS NOT NULL",
      "DROP INDEX IF EXISTS agent_configs_capability_idx"
    )

    # --- Tool Configs (replaces per-project DETS) ---

    create table(:tool_configs, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, on_delete: :delete_all)
      add :user_id, :bigint
      add :name, :string, null: false
      add :description, :text
      add :system, :boolean, default: false, null: false

      # HTTP config
      add :method, :string, default: "GET"
      add :url_template, :string
      add :headers, :map, default: %{}
      add :parameters, {:array, :map}, default: []
      add :response_type, :string
      add :response_path, :string
      add :kind, :string, default: "read"

      # Capability index
      add :capability_embedding, :vector, size: 1536

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_configs, [:project_id])
    create index(:tool_configs, [:user_id, :project_id])
    create unique_index(:tool_configs, [:project_id, :name])

    execute(
      "CREATE INDEX tool_configs_capability_idx ON tool_configs USING hnsw (capability_embedding vector_cosine_ops) WHERE capability_embedding IS NOT NULL",
      "DROP INDEX IF EXISTS tool_configs_capability_idx"
    )
  end
end
