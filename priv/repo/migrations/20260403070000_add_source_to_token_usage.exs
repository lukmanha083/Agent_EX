defmodule AgentEx.Repo.Migrations.AddSourceToTokenUsage do
  use Ecto.Migration

  def change do
    alter table(:project_token_usage) do
      add :source, :string, default: "orchestrator", null: false
    end

    create index(:project_token_usage, [:project_id, :source])
  end
end
