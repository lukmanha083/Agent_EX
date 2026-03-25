defmodule AgentEx.Repo.Migrations.AddProviderAndModelToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :provider, :string, default: "openai"
      add :model, :string, default: "gpt-4o-mini"
      add :provider_api_key, :binary
    end
  end
end
