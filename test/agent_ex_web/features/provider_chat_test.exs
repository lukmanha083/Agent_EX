defmodule AgentExWeb.Features.ProviderChatTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

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

  describe "provider/model reflected in chat" do
    test "chat page shows project model in badge", %{session: session, project: project} do
      session = visit(session, "/chat")
      source = page_source(session)
      assert source =~ project.model
    end
  end
end
