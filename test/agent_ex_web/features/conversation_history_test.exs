defmodule AgentExWeb.Features.ConversationHistoryTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  alias AgentEx.Chat

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    project = project_fixture(user)
    session = feature_log_in_user(session, user)

    # Switch to the test project
    execute_script(session, """
      const form = document.getElementById('desktop-project-form') || document.getElementById('mobile-project-form');
      if (form) { form.action = '/projects/switch/#{project.id}'; form.submit(); }
    """)

    :timer.sleep(1000)

    {:ok, session: session, user: user, project: project}
  end

  describe "conversation creation and sidebar" do
    test "new conversation appears in sidebar after toggling history", %{
      session: session,
      user: user,
      project: project
    } do
      # Pre-create a conversation via DB so sidebar has content
      {:ok, convo} =
        Chat.create_conversation(%{
          user_id: user.id,
          project_id: project.id,
          title: "Test conversation",
          model: "gpt-4o-mini",
          provider: "openai"
        })

      session
      |> resize_window(1280, 900)
      |> visit("/chat/#{convo.id}")
      |> click(css("button[aria-label='Toggle conversation history']"))
      |> assert_has(css("[data-testid='conversation-sidebar']"))
      |> assert_has(css("[data-testid='conversation-item-#{convo.id}']"))
    end

    test "empty chat shows empty state", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/chat")
      |> assert_has(css("[data-testid='empty-state']"))
    end
  end

  describe "conversation resume" do
    test "navigating to existing conversation loads messages from DB", %{
      session: session,
      user: user,
      project: project
    } do
      {:ok, convo} =
        Chat.create_conversation(%{
          user_id: user.id,
          project_id: project.id,
          title: "Resume test",
          model: "gpt-4o-mini",
          provider: "openai"
        })

      Chat.create_message!(%{conversation_id: convo.id, role: "user", content: "hello from DB"})

      Chat.create_message!(%{
        conversation_id: convo.id,
        role: "assistant",
        content: "response from DB"
      })

      session
      |> resize_window(1280, 900)
      |> visit("/chat/#{convo.id}")
      |> assert_has(css("[data-testid='messages']", text: "hello from DB"))
      |> assert_has(css("[data-testid='messages']", text: "response from DB"))
    end
  end

  describe "conversation deletion" do
    test "deleting conversation removes it and shows empty state", %{
      session: session,
      user: user,
      project: project
    } do
      {:ok, convo} =
        Chat.create_conversation(%{
          user_id: user.id,
          project_id: project.id,
          title: "Delete me",
          model: "gpt-4o-mini",
          provider: "openai"
        })

      session =
        session
        |> resize_window(1280, 900)
        |> visit("/chat/#{convo.id}")
        |> click(css("button[aria-label='Toggle conversation history']"))
        |> assert_has(css("[data-testid='conversation-item-#{convo.id}']"))

      accept_confirm(session, fn s ->
        click(
          s,
          css(
            "[data-testid='conversation-item-#{convo.id}'] button[aria-label='Delete conversation']"
          )
        )
      end)

      session
      |> assert_has(css("[data-testid='empty-state']"))
      |> refute_has(css("[data-testid='conversation-item-#{convo.id}']"))
    end
  end

  describe "responsive layout" do
    test "history panel hidden by default, visible after toggle", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/chat")
      |> refute_has(css("[data-testid='conversation-sidebar']"))
      |> click(css("button[aria-label='Toggle conversation history']"))
      |> assert_has(css("[data-testid='conversation-sidebar']"))
    end

    test "toggle button visible on mobile", %{session: session} do
      session
      |> resize_window(375, 812)
      |> visit("/chat")
      |> assert_has(css("button[aria-label='Toggle conversation history']"))
    end

    test "toggle button visible on tablet", %{session: session} do
      session
      |> resize_window(768, 1024)
      |> visit("/chat")
      |> assert_has(css("button[aria-label='Toggle conversation history']"))
    end
  end

  describe "clear conversation" do
    test "clear button navigates to empty state", %{
      session: session,
      user: user,
      project: project
    } do
      {:ok, convo} =
        Chat.create_conversation(%{
          user_id: user.id,
          project_id: project.id,
          title: "Clear test",
          model: "gpt-4o-mini",
          provider: "openai"
        })

      Chat.create_message!(%{conversation_id: convo.id, role: "user", content: "test msg"})

      session
      |> resize_window(1280, 900)
      |> visit("/chat/#{convo.id}")
      |> assert_has(css("[data-testid='messages']", text: "test msg"))
      |> click(css("button[aria-label='Clear conversation']"))
      |> assert_has(css("[data-testid='empty-state']"))
    end
  end
end
