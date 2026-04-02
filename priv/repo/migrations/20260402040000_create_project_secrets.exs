defmodule AgentEx.Repo.Migrations.CreateProjectSecrets do
  use Ecto.Migration

  def change do
    create table(:project_secrets) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :encrypted_value, :binary, null: false
      add :label, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:project_secrets, [:project_id, :key])
  end
end
