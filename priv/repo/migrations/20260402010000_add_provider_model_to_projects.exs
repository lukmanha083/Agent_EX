defmodule AgentEx.Repo.Migrations.AddProviderModelToProjects do
  use Ecto.Migration

  def up do
    # Add provider/model columns (nullable first for backfill)
    alter table(:projects) do
      add :provider, :string
      add :model, :string
      add :disabled_builtins, {:array, :string}, default: []
    end

    flush()

    # Backfill existing projects from their owner's user settings
    execute """
    UPDATE projects
    SET provider = u.provider,
        model = u.model,
        disabled_builtins = u.disabled_builtins
    FROM users u
    WHERE projects.user_id = u.id
    """

    # Set defaults for any projects that still have NULL (shouldn't happen, but safe)
    execute """
    UPDATE projects
    SET provider = 'anthropic',
        model = 'claude-sonnet-4-6'
    WHERE provider IS NULL
    """

    # Now make columns NOT NULL
    alter table(:projects) do
      modify :provider, :string, null: false
      modify :model, :string, null: false
    end
  end

  def down do
    alter table(:projects) do
      remove :provider
      remove :model
      remove :disabled_builtins
    end
  end
end
