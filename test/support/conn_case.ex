defmodule AgentExWeb.ConnCase do
  @moduledoc "Test case for Phoenix controller and LiveView tests."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AgentExWeb.Endpoint

      use AgentExWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import AgentExWeb.ConnCase
    end
  end

  setup tags do
    AgentEx.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    alias AgentEx.Accounts.Scope
    alias AgentEx.AccountsFixtures

    user = AccountsFixtures.user_fixture()
    project = AccountsFixtures.project_fixture(user)
    scope = Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    conn =
      conn
      |> log_in_user(user, opts)
      |> Plug.Conn.put_session(:current_project_id, project.id)

    %{conn: conn, user: user, project: project, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = AgentEx.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    AgentEx.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
