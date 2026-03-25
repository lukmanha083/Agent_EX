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
      |> assert_has(css("[data-component='dropdown-menu'][data-state='open']"))
      |> assert_has(css("[data-component='dropdown-menu'] a", text: "Profile"))
      |> assert_has(css("[data-component='dropdown-menu'] a", text: "Settings"))
      |> assert_has(css("[data-component='dropdown-menu'] a", text: "Sign out"))
    end

    test "closes on re-click of trigger", %{session: session} do
      session
      |> visit("/chat")
      |> click(css("#user-menu [data-part='trigger']"))
      |> assert_has(css("[data-component='dropdown-menu'][data-state='open']"))
      |> click(css("#user-menu [data-part='trigger']"))
      |> refute_has(css("[data-component='dropdown-menu'][data-state='open']"))
    end

    test "closes on outside click", %{session: session} do
      session
      |> visit("/chat")
      |> click(css("#user-menu [data-part='trigger']"))
      |> assert_has(css("[data-component='dropdown-menu'][data-state='open']"))
      # Click on the main content area to dismiss
      |> click(css("#messages"))
      |> refute_has(css("[data-component='dropdown-menu'][data-state='open']"))
    end
  end
end
