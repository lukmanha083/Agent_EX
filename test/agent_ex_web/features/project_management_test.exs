defmodule AgentExWeb.Features.ProjectManagementTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  alias AgentEx.{Chat, Projects}

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    session = feature_log_in_user(session, user)
    {:ok, session: session, user: user}
  end

  describe "project creation" do
    test "create a new project from the projects page", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/projects")
      |> assert_has(css("[data-testid='project-grid']"))
      |> click(css("[data-testid='new-project-btn']"))
      |> assert_has(css("[data-testid='project-editor']"))
      |> fill_in(css("input[name='name']"), with: "Research Project")
      |> fill_in(css("input[name='description']"), with: "ML research workspace")
      |> fill_in(css("input[name='anthropic_key']"), with: "sk-ant-test")
      |> fill_in(css("input[name='openai_key']"), with: "sk-test-key-for-ci")
      |> fill_in(css("input[name='root_path']"), with: "/tmp/research")
      |> assert_has(css("input[name='root_path']"))
      |> click(button("Create Project"))
      |> assert_has(css("[role='alert']", text: "created"))
    end
  end

  describe "project switching and isolation" do
    test "switching projects isolates conversations", %{session: session, user: user} do
      root_a = "/tmp/agent_ex_test/project_a_#{System.unique_integer([:positive])}"
      root_b = "/tmp/agent_ex_test/project_b_#{System.unique_integer([:positive])}"
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      {:ok, project_a} =
        Projects.create_project(%{
          user_id: user.id,
          name: "Project A",
          root_path: root_a,
          provider: "anthropic",
          model: "claude-sonnet-4-6"
        })

      {:ok, project_b} =
        Projects.create_project(%{
          user_id: user.id,
          name: "Project B",
          root_path: root_b,
          provider: "anthropic",
          model: "claude-sonnet-4-6"
        })

      {:ok, _convo} =
        Chat.create_conversation(%{
          user_id: user.id,
          project_id: project_b.id,
          title: "B-only conversation",
          model: "gpt-4o-mini",
          provider: "openai"
        })

      # Switch to Project A first
      session = feature_switch_project(session, project_a)

      # Visit chat on Project A — should NOT see Project B's conversation
      session =
        session
        |> resize_window(1280, 900)
        |> visit("/chat")

      refute page_source(session) =~ "B-only conversation"

      # Switch to Project B
      session = feature_switch_project(session, project_b)

      session = visit(session, "/chat")
      assert page_source(session) =~ "B-only conversation"
    end
  end

  describe "project deletion" do
    test "delete project shows success flash", %{session: session, user: user} do
      root = "/tmp/agent_ex_test/temp_project_#{System.unique_integer([:positive])}"
      File.mkdir_p!(root)

      {:ok, project} =
        Projects.create_project(%{
          user_id: user.id,
          name: "Temp Project",
          root_path: root,
          provider: "anthropic",
          model: "claude-sonnet-4-6"
        })

      session =
        session
        |> resize_window(1280, 900)
        |> visit("/projects")
        |> assert_has(css("[data-testid='project-card-#{project.id}']"))

      # Hover to reveal hidden buttons, then click delete
      session
      |> hover(css("[data-testid='project-card-#{project.id}']"))

      accept_confirm(session, fn s ->
        click(
          s,
          css("button[aria-label='Delete project']", count: :any, at: 0)
        )
      end)

      session
      |> assert_has(css("[role='alert']", text: "Project deleted"))
      |> refute_has(css("[data-testid='project-card-#{project.id}']"))
    end
  end
end
