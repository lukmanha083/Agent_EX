defmodule AgentExWeb.Features.ProfileTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    session = feature_log_in_user(session, user)
    {:ok, session: session, user: user}
  end

  describe "profile page" do
    test "renders profile page with username and email forms", %{session: session} do
      session
      |> visit("/users/profile")
      |> assert_has(css("#username_form"))
      |> assert_has(css("#email_form"))
    end

    test "update username", %{session: session} do
      session
      |> visit("/users/profile")
      |> fill_in(css("#username_form input[name='user[username]']"), with: "new_username")
      |> click(button("Update username"))
      |> assert_has(css("p", text: "Username updated successfully", count: :any))
    end

    test "change email sends confirmation", %{session: session} do
      session
      |> visit("/users/profile")
      |> fill_in(css("#email_form input[name='user[email]']"), with: unique_user_email())
      |> click(button("Change email"))
      |> assert_has(css("p", text: "A link to confirm your email", count: :any))
    end
  end
end
