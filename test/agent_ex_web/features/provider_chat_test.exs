defmodule AgentExWeb.Features.ProviderChatTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  alias AgentEx.Projects

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    # The default project gets provider/model from register_user
    project = Projects.get_default_project(user.id)
    session = feature_log_in_user(session, user)
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
