defmodule AgentEx.Repo.Migrations.CreateProjectTokenUsage do
  use Ecto.Migration

  def change do
    create table(:project_token_usage) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, default: 0, null: false
      add :output_tokens, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:project_token_usage, [:project_id])
    create index(:project_token_usage, [:project_id, :inserted_at])

    alter table(:projects) do
      add :token_budget, :bigint
    end
  end
end
