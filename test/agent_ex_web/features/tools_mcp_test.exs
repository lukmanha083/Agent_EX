defmodule AgentExWeb.Features.ToolsMcpTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  alias AgentEx.Projects

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()

    {:ok, project} =
      Projects.create_project(%{user_id: user.id, name: "Tools Project"})

    session = feature_log_in_user(session, user)

    # Switch to the test project
    execute_script(session, """
      const form = document.getElementById('desktop-project-form') || document.getElementById('mobile-project-form');
      if (form) { form.action = '/projects/switch/#{project.id}'; form.submit(); }
    """)

    :timer.sleep(1000)

    {:ok, session: session, user: user, project: project}
  end

  describe "MCP server connection" do
    test "blank fields are rejected with error flash", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/tools")
      # Click MCP Servers tab (SaladUI renders as button with text)
      |> click(button("MCP Servers"))
      # Open the MCP connect dialog
      |> click(button("Connect"))
      |> assert_has(css("[data-testid='mcp-dialog']"))

      # Fill with whitespace-only values (bypasses HTML required, caught by server-side trim)
      session
      |> fill_in(css("[data-testid='mcp-dialog'] input[name='name']"), with: "   ")
      |> fill_in(css("[data-testid='mcp-dialog'] input[name='command']"), with: "   ")

      # Remove required attr so browser allows submit
      execute_script(session, """
        document.querySelectorAll('[data-testid="mcp-dialog"] input[required]').forEach(el => el.removeAttribute('required'));
      """)

      session
      |> click(css("[data-testid='mcp-dialog'] button[type='submit']"))
      |> assert_has(css("[role='alert']", text: "Name and command are required"))
    end

    test "valid MCP server is added with success flash", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/tools")
      |> click(button("MCP Servers"))
      |> click(button("Connect"))
      |> assert_has(css("[data-testid='mcp-dialog']"))
      |> fill_in(css("[data-testid='mcp-dialog'] input[name='name']"), with: "sqlite-server")
      |> fill_in(css("[data-testid='mcp-dialog'] input[name='command']"), with: "npx mcp-sqlite")
      |> click(css("[data-testid='mcp-dialog'] button[type='submit']"))
      |> assert_has(css("[role='alert']", text: "MCP server 'sqlite-server' added"))
    end
  end

  describe "tools page gate" do
    test "default project shows 'create project first'", %{session: session, user: user} do
      default_project = Projects.get_default_project(user.id)

      execute_script(session, """
        const form = document.getElementById('desktop-project-form') || document.getElementById('mobile-project-form');
        if (form) { form.action = '/projects/switch/#{default_project.id}'; form.submit(); }
      """)

      :timer.sleep(1000)

      session
      |> resize_window(1280, 900)
      |> visit("/tools")
      |> assert_has(css("h2", text: "Create a project first"))
    end
  end
end
