defmodule AgentEx.Repo.Migrations.AddNotNullToProviderAndModel do
  use Ecto.Migration

  def change do
    alter table(:users) do
      modify :provider, :string, null: false, default: "openai"
      modify :model, :string, null: false, default: "gpt-4o-mini"
    end
  end
end
