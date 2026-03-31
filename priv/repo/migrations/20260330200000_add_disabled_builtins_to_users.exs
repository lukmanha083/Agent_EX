defmodule AgentEx.Repo.Migrations.AddDisabledBuiltinsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :disabled_builtins, {:array, :string}, default: [], null: false
    end
  end
end
