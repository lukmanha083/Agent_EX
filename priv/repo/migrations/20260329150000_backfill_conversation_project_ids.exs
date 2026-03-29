defmodule AgentEx.Repo.Migrations.BackfillConversationProjectIds do
  use Ecto.Migration

  def up do
    # Set project_id for any existing conversations that have NULL project_id
    # by assigning them to each user's default project.
    execute("""
    UPDATE conversations
    SET project_id = (
      SELECT p.id FROM projects p
      WHERE p.user_id = conversations.user_id AND p.is_default = true
      LIMIT 1
    )
    WHERE conversations.project_id IS NULL
    """)
  end

  def down do
    # No-op: we don't want to null out project_ids on rollback
    :ok
  end
end
