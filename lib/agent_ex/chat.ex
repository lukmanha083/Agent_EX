defmodule AgentEx.Chat do
  @moduledoc false
  import Ecto.Query

  alias AgentEx.Chat.{Conversation, Message}
  alias AgentEx.Repo

  # -- Conversations --

  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def get_conversation!(id), do: Repo.get!(Conversation, id)

  def get_conversation(id), do: Repo.get(Conversation, id)

  def get_user_conversation(user_id, conversation_id) do
    Repo.get_by(Conversation, id: conversation_id, user_id: user_id)
  end

  def list_conversations(user_id) do
    Conversation
    |> where(user_id: ^user_id)
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  def update_conversation_title(%Conversation{} = conversation, title) do
    conversation
    |> Conversation.changeset(%{title: title})
    |> Repo.update()
  end

  def delete_conversation(%Conversation{} = conversation) do
    Repo.delete(conversation)
  end

  # -- Messages --

  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  def create_message!(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert!()
  end

  def list_messages(conversation_id) do
    Message
    |> where(conversation_id: ^conversation_id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def list_recent_messages(conversation_id, limit) do
    Message
    |> where(conversation_id: ^conversation_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  # -- Convenience --

  def touch_conversation(%Conversation{} = conversation) do
    conversation
    |> Ecto.Changeset.change(updated_at: DateTime.utc_now())
    |> Repo.update()
  end

  def auto_title(content) do
    content
    |> String.trim()
    |> String.slice(0, 50)
    |> then(fn title ->
      if String.length(content) > 50, do: title <> "...", else: title
    end)
  end
end
