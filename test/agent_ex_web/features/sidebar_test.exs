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
    test "mobile (375px): shows mobile top bar with hamburger menu", %{session: session} do
      session
      |> resize_window(375, 812)
      |> visit("/chat")
      |> assert_has(css("#mobile-nav [data-part='trigger']"))
    end

    test "tablet (768px): shows mobile top bar (sidebar hidden below lg)", %{session: session} do
      session
      |> resize_window(768, 1024)
      |> visit("/chat")
      |> assert_has(css("#mobile-nav [data-part='trigger']"))
    end

    test "desktop (1280px): shows full sidebar with user menu", %{session: session} do
      session
      |> resize_window(1280, 900)
      |> visit("/chat")
      |> assert_has(css("#user-menu"))
    end
  end
end
