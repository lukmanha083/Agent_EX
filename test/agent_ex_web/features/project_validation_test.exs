defmodule AgentExWeb.Features.ProjectValidationTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    session = feature_log_in_user(session, user)
    {:ok, session: session, user: user}
  end

  describe "project root_path validation" do
    test "rejects tilde path with error", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/projects/new")
      |> assert_has(css("[data-testid='project-editor']"))
      |> fill_in(css("input[name='name']"), with: "Bad Path Project")
      |> fill_in(css("input[name='root_path']"), with: "~/projects/bad")
      |> fill_in(css("input[name='embedding_key']"), with: "sk-test-key")
      |> click(button("Create Project"))
      |> assert_has(css("[role='alert']", text: "absolute path"))
    end

    test "rejects relative path with error", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/projects/new")
      |> assert_has(css("[data-testid='project-editor']"))
      |> fill_in(css("input[name='name']"), with: "Relative Path Project")
      |> fill_in(css("input[name='root_path']"), with: "relative/path")
      |> fill_in(css("input[name='embedding_key']"), with: "sk-test-key")
      |> click(button("Create Project"))
      |> assert_has(css("[role='alert']", text: "absolute path"))
    end

    test "accepts valid absolute path", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/projects/new")
      |> assert_has(css("[data-testid='project-editor']"))
      |> fill_in(css("input[name='name']"), with: "Good Project")
      |> fill_in(css("input[name='root_path']"), with: "/tmp/valid_project")
      |> fill_in(css("input[name='embedding_key']"), with: "sk-test-key")
      |> click(button("Create Project"))
      |> assert_has(css("[role='alert']", text: "created"))
    end
  end
end
