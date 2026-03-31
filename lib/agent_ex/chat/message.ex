defmodule AgentEx.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversation_messages" do
    belongs_to(:conversation, AgentEx.Chat.Conversation)

    field(:role, :string)
    field(:content, :string)
    field(:metadata, :map)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_roles ~w(user assistant system orchestrator agent)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :role, :content, :metadata])
    |> validate_required([:conversation_id, :role, :content])
    |> validate_inclusion(:role, @valid_roles)
    |> foreign_key_constraint(:conversation_id)
  end
end
