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
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  def list_recent_messages(conversation_id, limit) do
    Message
    |> where(conversation_id: ^conversation_id)
    |> order_by(desc: :inserted_at, desc: :id)
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
    trimmed = String.trim(content)
    title = String.slice(trimmed, 0, 50)

    if String.length(trimmed) > 50, do: title <> "...", else: title
  end

  def generate_title_async(
        %Conversation{} = conversation,
        user_message,
        assistant_message,
        opts \\ []
      ) do
    notify_pid = Keyword.get(opts, :notify_pid)

    Task.Supervisor.start_child(AgentEx.TaskSupervisor, fn ->
      do_generate_title(conversation, user_message, assistant_message, notify_pid)
    end)
  end

  defp do_generate_title(conversation, user_message, assistant_message, notify_pid) do
    client =
      AgentEx.ModelClient.new(
        model: conversation.model,
        provider: safe_provider_atom(conversation.provider)
      )

    messages = [
      AgentEx.Message.system("""
      Summarize this conversation in 2-5 words as a short title.
      Rules: No apologies. No filler words. No quotes. No punctuation.
      Just the topic. Examples: "Disk Space Check", "System OS Info", "Weather Forecast".
      """),
      AgentEx.Message.user(
        "User: #{String.slice(user_message, 0, 200)}\n" <>
          "Assistant: #{String.slice(assistant_message, 0, 200)}"
      )
    ]

    with {:ok, response} <- AgentEx.ModelClient.create(client, messages),
         title when title != "" <- clean_title(response.content) do
      update_conversation_title(conversation, title)
      if notify_pid, do: send(notify_pid, {:title_updated, conversation.id, title})
    end
  end

  defp clean_title(raw) do
    raw
    |> String.trim()
    |> String.trim("\"")
    |> String.replace(~r/^["'\s]+|["'\s]+$/, "")
    |> String.slice(0, 60)
  end

  defp safe_provider_atom(provider) when provider in ["openai", "anthropic", "moonshot"],
    do: String.to_existing_atom(provider)

  defp safe_provider_atom(_), do: :openai
end
