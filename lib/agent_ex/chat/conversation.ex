defmodule AgentEx.Chat.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    belongs_to :user, AgentEx.Accounts.User
    has_many :messages, AgentEx.Chat.Message

    field :title, :string
    field :model, :string
    field :provider, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_id, :title, :model, :provider])
    |> validate_required([:user_id, :model, :provider])
    |> foreign_key_constraint(:user_id)
  end
end
