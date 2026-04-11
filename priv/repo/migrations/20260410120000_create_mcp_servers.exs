defmodule AgentEx.Repo.Migrations.CreateMcpServers do
  use Ecto.Migration

  def change do
    create table(:mcp_servers, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :url, :string, null: false
      add :provider, :string, default: "anthropic", null: false
      add :enabled, :boolean, default: true, null: false
      add :auth_token_key, :string
      add :tools_filter, {:array, :string}, default: []

      timestamps()
    end

    create index(:mcp_servers, [:project_id])
    create unique_index(:mcp_servers, [:project_id, :name])
  end
end
