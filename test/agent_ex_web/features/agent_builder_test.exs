defmodule AgentExWeb.Features.AgentBuilderTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  alias AgentEx.{AgentStore, Projects}

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()

    {:ok, project} =
      Projects.create_project(%{
        user_id: user.id,
        name: "Test Project",
        root_path: "/tmp/test",
        provider: "anthropic",
        model: "claude-sonnet-4-6"
      })

    session = feature_log_in_user(session, user)

    # Switch to the test project
    execute_script(session, """
      const form = document.getElementById('desktop-project-form') || document.getElementById('mobile-project-form');
      if (form) { form.action = '/projects/switch/#{project.id}'; form.submit(); }
    """)

    :timer.sleep(1000)

    {:ok, session: session, user: user, project: project}
  end

  describe "agent creation" do
    test "create agent with name and role", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/agents")
      |> assert_has(css("[data-testid='agent-grid']"))
      |> click(css("[data-testid='new-agent-btn']"))
      |> assert_has(css("[data-testid='agent-editor']"))
      |> fill_in(css("input[name='name']"), with: "Security Auditor")
      |> fill_in(css("input[name='role']"), with: "Senior security analyst")
      |> click(button("Create Agent"))
      |> assert_has(css("[data-testid='agent-grid']", text: "Security Auditor"))
    end

    test "create agent with intervention pipeline", %{session: session} do
      session =
        session
        |> resize_window(1280, 900)
        |> visit("/agents")
        |> click(css("[data-testid='new-agent-btn']"))
        |> assert_has(css("[data-testid='agent-editor']"))
        |> fill_in(css("input[name='name']"), with: "Guarded Agent")

      # Enable the log handler toggle
      click(session, css("[phx-click='add_handler'][phx-value-id='log_handler']"))
      # Enable the permission handler toggle
      click(session, css("[phx-click='add_handler'][phx-value-id='permission_handler']"))

      session
      |> click(button("Create Agent"))
      |> assert_has(css("[data-testid='agent-grid']", text: "Guarded Agent"))
      |> assert_has(css("[data-testid='agent-grid']", text: "2 handlers"))
    end
  end

  describe "agent deletion" do
    test "delete agent shows flash feedback", %{session: session, user: user, project: project} do
      config =
        AgentEx.AgentConfig.new(%{
          user_id: user.id,
          project_id: project.id,
          name: "Delete Me"
        })

      {:ok, config} = AgentStore.save(config)

      session =
        session
        |> resize_window(1280, 900)
        |> visit("/agents")
        |> assert_has(css("[data-testid='agent-card-#{config.id}']"))

      # Hover to reveal hidden buttons
      hover(session, css("[data-testid='agent-card-#{config.id}']"))

      accept_confirm(session, fn s ->
        click(s, css("button[aria-label='Delete agent']", count: :any, at: 0))
      end)

      session
      |> assert_has(css("[role='alert']", text: "Agent deleted"))
      |> refute_has(css("[data-testid='agent-card-#{config.id}']"))
    end
  end
end
