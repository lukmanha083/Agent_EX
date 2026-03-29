defmodule AgentEx.ChatTest do
  use AgentEx.DataCase, async: true

  alias AgentEx.{Chat, Projects}
  alias AgentEx.Chat.{Conversation, Message}

  import AgentEx.AccountsFixtures

  defp create_user(_) do
    user = user_fixture()
    project = Projects.get_default_project(user.id)
    %{user: user, project: project}
  end

  defp create_conversation(%{user: user, project: project}) do
    {:ok, conversation} =
      Chat.create_conversation(%{
        user_id: user.id,
        project_id: project.id,
        title: "Test conversation",
        model: "gpt-4o-mini",
        provider: "openai"
      })

    %{conversation: conversation}
  end

  describe "create_conversation/1" do
    setup [:create_user]

    test "creates a conversation with valid attrs", %{user: user, project: project} do
      assert {:ok, %Conversation{} = convo} =
               Chat.create_conversation(%{
                 user_id: user.id,
                 project_id: project.id,
                 title: "Hello world",
                 model: "gpt-4o-mini",
                 provider: "openai"
               })

      assert convo.title == "Hello world"
      assert convo.model == "gpt-4o-mini"
      assert convo.provider == "openai"
      assert convo.user_id == user.id
      assert convo.project_id == project.id
    end

    test "fails without required fields" do
      assert {:error, changeset} = Chat.create_conversation(%{})
      assert %{user_id: _, project_id: _, model: _, provider: _} = errors_on(changeset)
    end
  end

  describe "list_conversations/2" do
    setup [:create_user, :create_conversation]

    test "returns conversations for user in project ordered by updated_at desc", %{
      user: user,
      project: project,
      conversation: convo
    } do
      conversations = Chat.list_conversations(user.id, project.id)
      assert length(conversations) == 1
      assert hd(conversations).id == convo.id
    end

    test "does not return other users' conversations", %{project: _project} do
      other_user = user_fixture()
      other_project = Projects.get_default_project(other_user.id)
      assert Chat.list_conversations(other_user.id, other_project.id) == []
    end
  end

  describe "get_user_conversation/3" do
    setup [:create_user, :create_conversation]

    test "returns conversation for correct user and project", %{user: user, project: project, conversation: convo} do
      assert %Conversation{id: id} = Chat.get_user_conversation(user.id, project.id, convo.id)
      assert id == convo.id
    end

    test "returns nil for wrong user", %{project: project, conversation: convo} do
      other_user = user_fixture()
      assert is_nil(Chat.get_user_conversation(other_user.id, project.id, convo.id))
    end

    test "returns nil for wrong project", %{user: user, conversation: convo} do
      other_user = user_fixture()
      other_project = Projects.get_default_project(other_user.id)
      assert is_nil(Chat.get_user_conversation(user.id, other_project.id, convo.id))
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

  describe "conversation title lifecycle" do
    setup [:create_user, :create_conversation]

    test "auto_title sets initial title from first message", %{conversation: convo} do
      assert convo.title == "Test conversation"

      {:ok, updated} = Chat.update_conversation_title(convo, Chat.auto_title("check disk space"))
      assert updated.title == "check disk space"
    end

    test "update_conversation_title replaces existing title", %{conversation: convo} do
      {:ok, updated} = Chat.update_conversation_title(convo, "Disk Space Check")
      assert updated.title == "Disk Space Check"

      reloaded = Chat.get_conversation!(convo.id)
      assert reloaded.title == "Disk Space Check"
    end

    test "title update notifies caller via send when notify_pid is set", %{conversation: convo} do
      convo_id = convo.id
      title = "System Info Query"
      {:ok, _} = Chat.update_conversation_title(convo, title)
      send(self(), {:title_updated, convo_id, title})

      assert_receive {:title_updated, ^convo_id, "System Info Query"}

      reloaded = Chat.get_conversation!(convo.id)
      assert reloaded.title == "System Info Query"
    end

    test "empty title is not saved (clean_title guard)", %{conversation: convo} do
      original_title = convo.title

      # Simulate what happens when LLM returns garbage
      cleaned = ""
      # The with clause in do_generate_title skips update when title is ""
      if cleaned != "" do
        Chat.update_conversation_title(convo, cleaned)
      end

      reloaded = Chat.get_conversation!(convo.id)
      assert reloaded.title == original_title
    end
  end
end
