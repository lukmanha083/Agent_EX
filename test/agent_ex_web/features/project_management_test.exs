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
      |> fill_in(css("input[name='root_path']"), with: "/tmp/research")
      |> click(button("Create Project"))
      |> assert_has(css("[data-testid='project-grid']", text: "Research Project"))
    end
  end

  describe "project switching and isolation" do
    test "switching projects isolates conversations", %{session: session, user: user} do
      {:ok, project_b} =
        Projects.create_project(%{user_id: user.id, name: "Project B"})

      {:ok, _convo} =
        Chat.create_conversation(%{
          user_id: user.id,
          project_id: project_b.id,
          title: "B-only conversation",
          model: "gpt-4o-mini",
          provider: "openai"
        })

      # Visit chat on default project — should NOT see Project B's conversation
      session =
        session
        |> resize_window(1280, 900)
        |> visit("/chat")

      refute page_source(session) =~ "B-only conversation"

      # Switch to Project B via form submission
      execute_script(session, """
        const form = document.getElementById('desktop-project-form');
        form.action = '/projects/switch/#{project_b.id}';
        form.submit();
      """)

      :timer.sleep(1000)

      session = visit(session, "/chat")
      assert page_source(session) =~ "B-only conversation"
    end
  end

  describe "project deletion" do
    test "delete project shows success flash", %{session: session, user: user} do
      {:ok, project} =
        Projects.create_project(%{user_id: user.id, name: "Temp Project"})

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

    test "cannot delete the default project (no delete button)", %{session: session, user: user} do
      default_project = Projects.get_default_project(user.id)

      session
      |> resize_window(1280, 900)
      |> visit("/projects")
      |> assert_has(css("[data-testid='project-card-#{default_project.id}']"))
      |> refute_has(
        css(
          "[data-testid='project-card-#{default_project.id}'] button[aria-label='Delete project']",
          visible: false
        )
      )
    end
  end
end
