defmodule AgentExWeb.FeatureCase do
  @moduledoc "Test case for Wallaby browser-based feature/E2E tests."

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      @endpoint AgentExWeb.Endpoint

      import Wallaby.Query
      import AgentExWeb.FeatureCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AgentEx.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(AgentEx.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    {:ok, session: session}
  end

  @doc "Creates a user and logs them in via the browser session."
  def feature_log_in_user(session, user) do
    import Wallaby.Browser
    import Wallaby.Query

    password = AgentEx.AccountsFixtures.valid_user_password()
    AgentEx.AccountsFixtures.set_password(user)

    session
    |> visit("/users/log-in")
    |> fill_in(css("#login_form_password_email"), with: user.email)
    |> fill_in(css("#login_form_password_password"), with: password)
    |> click(css("#login_form_password button"))
    |> assert_has(css("main"))
  end

  @doc "Switches the browser session to the given project and waits for navigation."
  def feature_switch_project(session, project) do
    import Wallaby.Browser
    import Wallaby.Query

    execute_script(session, """
      const form = document.getElementById('desktop-project-form') || document.getElementById('mobile-project-form');
      if (form) { form.action = '/projects/switch/#{project.id}'; form.submit(); }
    """)

    # Wait for the POST → redirect → page load instead of a fixed sleep.
    # The switch redirects to the referer or /chat; either way, `main` loads.
    assert_has(session, css("main"))
    session
  end
end
