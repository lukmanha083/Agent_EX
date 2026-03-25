defmodule AgentExWeb.Features.LoginTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  describe "login page" do
    test "renders both login forms in the browser", %{session: session} do
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
      |> fill_in(css("#login_form_magic_email"), with: user.email)
      |> click(css("#login_form_magic button"))
      |> assert_has(css("p", text: "If your email is in our system", count: :any))
    end

    test "navigates to registration page", %{session: session} do
      session
      |> visit("/users/log-in")
      |> click(link("Sign up"))
      |> assert_has(css("h1", text: "Create an account"))
    end
  end

  describe "registration page" do
    test "renders registration form", %{session: session} do
      session
      |> visit("/users/register")
      |> assert_has(css("h1", text: "Create an account"))
      |> assert_has(css("#registration_form"))
    end

    test "navigates to login page", %{session: session} do
      session
      |> visit("/users/register")
      |> click(link("Sign in"))
      |> assert_has(css("h1", text: "Sign in"))
    end
  end
end
