defmodule AgentExWeb.Features.ProviderChatTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    session = feature_log_in_user(session, user)
    {:ok, session: session, user: user}
  end

  describe "provider/model reflected in chat" do
    test "chat page shows current model in badge", %{session: session, user: user} do
      session = visit(session, "/chat")
      source = page_source(session)
      assert source =~ user.model || "gpt-4o-mini"
    end

    test "changing provider in settings persists", %{session: session} do
      session =
        session
        |> visit("/users/settings")
        |> execute_script("""
          const sel = document.querySelector('#provider_form select[name="user[provider]"]');
          sel.value = 'anthropic';
          sel.dispatchEvent(new Event('input', { bubbles: true }));
        """)
        |> click(button("Update provider"))
        |> assert_has(css("p", text: "Provider updated successfully", count: :any))

      session = visit(session, "/users/settings")
      source = page_source(session)
      assert source =~ "anthropic"
    end
  end
end
