defmodule AgentEx.Repo.Migrations.AddNotNullToProviderAndModel do
  use Ecto.Migration

  def change do
    execute "UPDATE users SET provider = 'openai' WHERE provider IS NULL",
            "SELECT 1"

    execute "UPDATE users SET model = 'gpt-4o-mini' WHERE model IS NULL",
            "SELECT 1"

    alter table(:users) do
      modify :provider, :string, null: false, default: "openai"
      modify :model, :string, null: false, default: "gpt-4o-mini"
    end
  end
end
