defmodule AgentExWeb.Features.SettingsTest do
  use AgentExWeb.FeatureCase

  import AgentEx.AccountsFixtures

  @moduletag :feature

  setup %{session: session} do
    user = user_fixture()
    session = feature_log_in_user(session, user)
    {:ok, session: session, user: user}
  end

  describe "settings page" do
    test "renders settings page with all forms", %{session: session} do
      session
      |> visit("/users/settings")
      |> assert_has(css("h1", text: "Settings"))
      |> assert_has(css("#timezone_form"))
      |> assert_has(css("#password_form"))
    end

    test "update timezone", %{session: session} do
      session
      |> visit("/users/settings")
      |> execute_script("""
        const sel = document.querySelector('#timezone_form select[name="user[timezone]"]');
        sel.value = 'Asia/Tokyo';
        sel.dispatchEvent(new Event('change', { bubbles: true }));
      """)
      |> click(button("Update timezone"))
      |> assert_has(css("p", text: "Timezone updated successfully", count: :any))
    end

    test "update password", %{session: session} do
      new_password = "new_secure_password_123"

      session
      |> visit("/users/settings")
      |> fill_in(css("#password_form input[name='user[password]']"), with: new_password)
      |> fill_in(css("#password_form input[name='user[password_confirmation]']"),
        with: new_password
      )
      |> click(button("Save password"))
      |> assert_has(css("p", text: "Password updated successfully", count: :any))
    end
  end
end
