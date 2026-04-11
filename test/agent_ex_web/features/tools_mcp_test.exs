defmodule AgentExWeb.Features.ToolsMcpTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  alias AgentEx.Projects

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    root = "/tmp/agent_ex_test/tools_mcp_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} =
      Projects.create_project(%{
        user_id: user.id,
        name: "Tools Project",
        root_path: root,
        provider: "anthropic",
        model: "claude-sonnet-4-6"
      })

    session = feature_log_in_user(session, user)
    session = feature_switch_project(session, project)

    {:ok, session: session, user: user, project: project}
  end

  describe "MCP server connection" do
    test "blank fields are rejected with error flash", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/tools")
      # Click MCP (Client) tab (SaladUI renders as button with text)
      |> click(button("MCP (Client)"))
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
      |> click(button("MCP (Client)"))
      |> click(button("Connect"))
      |> assert_has(css("[data-testid='mcp-dialog']"))
      |> fill_in(css("[data-testid='mcp-dialog'] input[name='name']"), with: "sqlite-server")
      |> fill_in(css("[data-testid='mcp-dialog'] input[name='command']"), with: "npx mcp-sqlite")
      |> click(css("[data-testid='mcp-dialog'] button[type='submit']"))
      |> assert_has(css("[role='alert']", text: "MCP server 'sqlite-server' added"))
    end
  end
end
