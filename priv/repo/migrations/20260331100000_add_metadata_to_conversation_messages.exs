defmodule AgentEx.Repo.Migrations.AddMetadataToConversationMessages do
  use Ecto.Migration

  def change do
    alter table(:conversation_messages) do
      add(:metadata, :map)
    end
  end
end
