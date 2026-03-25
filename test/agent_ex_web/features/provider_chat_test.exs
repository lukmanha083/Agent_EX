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
    test "changing provider in settings updates model badge in chat", %{session: session} do
      # Change provider to anthropic in settings
      session =
        session
        |> visit("/users/settings")
        |> execute_script("""
          const sel = document.querySelector('#provider_form select[name="user[provider]"]');
          sel.value = 'anthropic';
          sel.dispatchEvent(new Event('change', { bubbles: true }));
        """)
        |> click(button("Update provider"))
        |> assert_has(css("p", text: "Provider updated successfully", count: :any))

      # Navigate to chat and verify the model badge shows an Anthropic model
      session
      |> visit("/chat")
      |> assert_has(css("span", text: "claude-", count: :any))
    end
  end
end
