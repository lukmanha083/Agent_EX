defmodule AgentExWeb.Features.ProviderChatTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    project = project_fixture(user)
    session = feature_log_in_user(session, user)
    session = feature_switch_project(session, project)

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
