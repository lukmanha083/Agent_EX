defmodule AgentExWeb.Features.ImportAgentTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  alias AgentEx.Projects

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    root = "/tmp/agent_ex_test/import_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} =
      Projects.create_project(%{
        user_id: user.id,
        name: "Import Test",
        root_path: root,
        provider: "anthropic",
        model: "claude-sonnet-4-6"
      })

    session = feature_log_in_user(session, user)

    execute_script(session, """
      const form = document.getElementById('desktop-project-form') || document.getElementById('mobile-project-form');
      if (form) { form.action = '/projects/switch/#{project.id}'; form.submit(); }
    """)

    :timer.sleep(1000)

    {:ok, session: session, user: user, project: project}
  end

  defp open_import_dialog(session) do
    session
    |> resize_window(1280, 900)
    |> visit("/agents")
    |> click(css("[phx-click='show_import']"))
    |> assert_has(css("[role='dialog']"))
  end

  describe "JSON import — valid" do
    test "import valid JSON creates agent and shows it in grid", %{session: session} do
      valid_json =
        Jason.encode!(%{
          "name" => "Imported Bot",
          "role" => "assistant",
          "expertise" => ["elixir", "testing"],
          "goal" => "Help with code reviews"
        })

      session
      |> open_import_dialog()
      |> fill_in(css("textarea[name='json_content']"), with: valid_json)
      |> click(css("button[type='submit']", text: "Import"))
      |> assert_has(css("[role='alert']", text: "Agent imported"))
      |> assert_has(css("[data-testid='agent-grid']", text: "Imported Bot"))
    end
  end

  describe "JSON import — invalid inputs" do
    test "rejects invalid JSON with error flash", %{session: session} do
      session
      |> open_import_dialog()
      |> fill_in(css("textarea[name='json_content']"), with: "{not valid json")
      |> click(css("button[type='submit']", text: "Import"))
      |> assert_has(css("[role='alert']", text: "Invalid JSON"))
    end

    test "rejects JSON array with error flash", %{session: session} do
      session
      |> open_import_dialog()
      |> fill_in(css("textarea[name='json_content']"), with: "[1, 2, 3]")
      |> click(css("button[type='submit']", text: "Import"))
      |> assert_has(css("[role='alert']", text: "JSON must be an object"))
    end

    test "rejects JSON missing name field", %{session: session} do
      no_name_json = Jason.encode!(%{"role" => "assistant"})

      session
      |> open_import_dialog()
      |> fill_in(css("textarea[name='json_content']"), with: no_name_json)
      |> click(css("button[type='submit']", text: "Import"))
      |> assert_has(css("[role='alert']", text: "name"))
    end

    test "closing import dialog with cancel button", %{session: session} do
      session
      |> open_import_dialog()
      |> assert_has(css("[role='dialog']"))
      |> click(css("button[phx-click='close_import']"))
      |> refute_has(css("[role='dialog']"))
    end
  end
end
