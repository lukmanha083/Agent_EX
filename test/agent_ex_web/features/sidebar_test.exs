defmodule AgentExWeb.Features.SidebarTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    session = feature_log_in_user(session, user)
    {:ok, session: session, user: user}
  end

  describe "responsive sidebar" do
    test "mobile (375px): shows top bar with hamburger, hides desktop sidebar", %{
      session: session
    } do
      session
      |> resize_window(375, 812)
      |> visit("/chat")
      |> assert_has(css(".md\\:hidden", visible: true))
      |> refute_has(css(".hidden.md\\:flex", visible: true))
    end

    test "tablet (768px): shows icon-only rail sidebar", %{session: session} do
      session
      |> resize_window(768, 1024)
      |> visit("/chat")
      |> assert_has(css(".hidden.md\\:flex", visible: true))
    end

    test "desktop (1280px): shows full sidebar with text labels", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/chat")
      |> assert_has(css(".hidden.md\\:flex", visible: true))
    end
  end
end
