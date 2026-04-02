defmodule AgentEx.Repo.Migrations.RemoveProviderModelFromUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      remove :provider
      remove :model
      remove :disabled_builtins
      remove :provider_api_key
    end
  end

  def down do
    alter table(:users) do
      add :provider, :string, default: "openai"
      add :model, :string, default: "gpt-4o-mini"
      add :disabled_builtins, {:array, :string}, default: []
      add :provider_api_key, :binary
    end
  end
end
