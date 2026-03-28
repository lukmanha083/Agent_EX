defmodule AgentEx.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :string
      add :root_path, :string
      add :is_default, :boolean, default: false, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:projects, [:user_id])
    create unique_index(:projects, [:user_id, :name])

    create unique_index(:projects, [:user_id],
      where: "is_default = true",
      name: :projects_one_default_per_user
    )

    alter table(:conversations) do
      add :project_id, references(:projects, on_delete: :delete_all)
    end

    create index(:conversations, [:project_id])
    create index(:conversations, [:project_id, :updated_at])
  end
end
