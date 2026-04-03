defmodule AgentEx.Repo.Migrations.RemoveIsDefaultFromProjects do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:projects, [:user_id], name: :projects_one_default_per_user)

    alter table(:projects) do
      remove :is_default
    end
  end

  def down do
    alter table(:projects) do
      add :is_default, :boolean, default: false, null: false
    end

    create unique_index(:projects, [:user_id],
      where: "is_default = true",
      name: :projects_one_default_per_user
    )
  end
end
