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
    |> fill_in(text_field("Email"), with: user.email)
    |> click(link("Sign in with password"))
    |> fill_in(text_field("Password"), with: password)
    |> click(button("Sign in"))
  end
end
