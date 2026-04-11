defmodule AgentEx.Repo.Migrations.AddSystemToMcpServers do
  use Ecto.Migration

  def change do
    alter table(:mcp_servers) do
      add :system, :boolean, default: false, null: false
    end

    # System MCP servers: unique by name where system=true (no project_id)
    create unique_index(:mcp_servers, [:name], where: "system = true", name: :mcp_servers_system_name_index)

    # Allow null project_id for system servers
    execute "ALTER TABLE mcp_servers ALTER COLUMN project_id DROP NOT NULL",
            "ALTER TABLE mcp_servers ALTER COLUMN project_id SET NOT NULL"
  end
end
