defmodule AgentExWeb.Features.DropdownTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    session = feature_log_in_user(session, user)
    # Desktop width so the sidebar avatar dropdown is visible
    session = resize_window(session, 1280, 900)
    {:ok, session: session, user: user}
  end

  describe "avatar dropdown" do
    test "opens on click and shows menu items", %{session: session} do
      session
      |> visit("/chat")
      |> click(css("#user-menu [data-part='trigger']"))
      |> assert_has(css("[data-state='open']", count: :any))
      |> assert_has(css("a", text: "Profile", count: :any))
      |> assert_has(css("a", text: "Settings", count: :any))
      |> assert_has(css("a", text: "Sign out", count: :any))
    end

    test "closes on re-click of trigger", %{session: session} do
      session =
        session
        |> visit("/chat")
        |> click(css("#user-menu [data-part='trigger']"))
        |> assert_has(css("[data-state='open']", count: :any))

      session
      |> click(css("#user-menu [data-part='trigger']"))
      |> refute_has(css("#user-menu [data-state='open']"))
    end

    test "closes on outside click", %{session: session} do
      session =
        session
        |> visit("/chat")
        |> click(css("#user-menu [data-part='trigger']"))
        |> assert_has(css("[data-state='open']", count: :any))

      # Click on the main content area to dismiss
      session
      |> click(css("#messages"))
      |> refute_has(css("#user-menu [data-state='open']"))
    end
  end
end
