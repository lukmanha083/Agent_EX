defmodule AgentEx.ChatTest do
  use AgentEx.DataCase, async: true

  alias AgentEx.Chat
  alias AgentEx.Chat.{Conversation, Message}

  import AgentEx.AccountsFixtures

  defp create_user(_), do: %{user: user_fixture()}

  defp create_conversation(%{user: user}) do
    {:ok, conversation} =
      Chat.create_conversation(%{
        user_id: user.id,
        title: "Test conversation",
        model: "gpt-4o-mini",
        provider: "openai"
      })

    %{conversation: conversation}
  end

  describe "create_conversation/1" do
    setup [:create_user]

    test "creates a conversation with valid attrs", %{user: user} do
      assert {:ok, %Conversation{} = convo} =
               Chat.create_conversation(%{
                 user_id: user.id,
                 title: "Hello world",
                 model: "gpt-4o-mini",
                 provider: "openai"
               })

      assert convo.title == "Hello world"
      assert convo.model == "gpt-4o-mini"
      assert convo.provider == "openai"
      assert convo.user_id == user.id
    end

    test "fails without required fields" do
      assert {:error, changeset} = Chat.create_conversation(%{})
      assert %{user_id: _, model: _, provider: _} = errors_on(changeset)
    end
  end

  describe "list_conversations/1" do
    setup [:create_user, :create_conversation]

    test "returns conversations for user ordered by updated_at desc", %{
      user: user,
      conversation: convo
    } do
      conversations = Chat.list_conversations(user.id)
      assert length(conversations) == 1
      assert hd(conversations).id == convo.id
    end

    test "does not return other users' conversations", %{conversation: _convo} do
      other_user = user_fixture()
      assert Chat.list_conversations(other_user.id) == []
    end
  end

  describe "get_user_conversation/2" do
    setup [:create_user, :create_conversation]

    test "returns conversation for correct user", %{user: user, conversation: convo} do
      assert %Conversation{id: id} = Chat.get_user_conversation(user.id, convo.id)
      assert id == convo.id
    end

    test "returns nil for wrong user", %{conversation: convo} do
      other_user = user_fixture()
      assert is_nil(Chat.get_user_conversation(other_user.id, convo.id))
    end
  end

  describe "update_conversation_title/2" do
    setup [:create_user, :create_conversation]

    test "updates the title", %{conversation: convo} do
      assert {:ok, updated} = Chat.update_conversation_title(convo, "New title")
      assert updated.title == "New title"
    end
  end

  describe "delete_conversation/1" do
    setup [:create_user, :create_conversation]

    test "deletes the conversation and its messages", %{conversation: convo} do
      Chat.create_message!(%{conversation_id: convo.id, role: "user", content: "hello"})

      assert {:ok, _} = Chat.delete_conversation(convo)
      assert is_nil(Chat.get_conversation(convo.id))
      assert Chat.list_messages(convo.id) == []
    end
  end

  describe "create_message/1" do
    setup [:create_user, :create_conversation]

    test "creates a message with valid attrs", %{conversation: convo} do
      assert {:ok, %Message{} = msg} =
               Chat.create_message(%{
                 conversation_id: convo.id,
                 role: "user",
                 content: "Hello!"
               })

      assert msg.role == "user"
      assert msg.content == "Hello!"
    end

    test "validates role inclusion", %{conversation: convo} do
      assert {:error, changeset} =
               Chat.create_message(%{
                 conversation_id: convo.id,
                 role: "invalid",
                 content: "test"
               })

      assert %{role: _} = errors_on(changeset)
    end
  end

  describe "list_messages/1" do
    setup [:create_user, :create_conversation]

    test "returns messages ordered by inserted_at asc", %{conversation: convo} do
      Chat.create_message!(%{conversation_id: convo.id, role: "user", content: "first"})
      Chat.create_message!(%{conversation_id: convo.id, role: "assistant", content: "second"})

      messages = Chat.list_messages(convo.id)
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "first"
      assert Enum.at(messages, 1).content == "second"
    end
  end

  describe "list_recent_messages/2" do
    setup [:create_user, :create_conversation]

    test "returns only the last N messages", %{conversation: convo} do
      for i <- 1..5 do
        Chat.create_message!(%{conversation_id: convo.id, role: "user", content: "msg #{i}"})
      end

      messages = Chat.list_recent_messages(convo.id, 2)
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "msg 4"
      assert Enum.at(messages, 1).content == "msg 5"
    end
  end

  describe "auto_title/1" do
    test "truncates long content at 50 chars with ellipsis" do
      long = String.duplicate("a", 60)
      title = Chat.auto_title(long)
      assert String.length(title) == 53
      assert String.ends_with?(title, "...")
    end

    test "keeps short content as-is" do
      assert Chat.auto_title("Short message") == "Short message"
    end

    test "trims whitespace" do
      assert Chat.auto_title("  hello  ") == "hello"
    end
  end
end
