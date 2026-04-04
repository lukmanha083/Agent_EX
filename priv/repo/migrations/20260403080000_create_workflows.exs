defmodule AgentEx.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :string
      add :nodes, :map, default: fragment("'[]'::jsonb"), null: false
      add :edges, :map, default: fragment("'[]'::jsonb"), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflows, [:project_id])
    create unique_index(:workflows, [:project_id, :name])
  end
end
