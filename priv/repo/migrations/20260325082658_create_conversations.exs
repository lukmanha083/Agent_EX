defmodule AgentEx.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string
      add :model, :string, null: false
      add :provider, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:user_id])
    create index(:conversations, [:user_id, :updated_at])

    create table(:conversation_messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:conversation_messages, [:conversation_id])
  end
end
