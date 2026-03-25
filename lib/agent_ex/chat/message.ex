defmodule AgentEx.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversation_messages" do
    belongs_to :conversation, AgentEx.Chat.Conversation

    field :role, :string
    field :content, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :role, :content])
    |> validate_required([:conversation_id, :role, :content])
    |> validate_inclusion(:role, ~w(user assistant system))
    |> foreign_key_constraint(:conversation_id)
  end
end
