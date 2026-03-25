defmodule AgentExWeb.Features.LoginTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  describe "login page" do
    test "renders login form in the browser", %{session: session} do
      session
      |> visit("/users/log-in")
      |> assert_has(css("h1", text: "Sign in"))
      |> assert_has(css("#login_form_magic"))
      |> assert_has(css("#login_form_password"))
    end

    test "magic link flow shows confirmation message", %{session: session} do
      user = user_fixture()

      session
      |> visit("/users/log-in")
      |> fill_in(text_field("Email", id: "login_form_magic_email"), with: user.email)
      |> click(button("Sign in with email"))
      |> assert_has(css("div", text: "If your email is in our system"))
    end

    test "navigates to registration page", %{session: session} do
      session
      |> visit("/users/log-in")
      |> click(link("Sign up"))
      |> assert_has(css("h1", text: "Create an account"))
    end
  end
end
