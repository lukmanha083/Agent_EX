defmodule AgentExWeb.Router do
  use AgentExWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:ensure_chat_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AgentExWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  defp ensure_chat_session(conn, _opts) do
    case Plug.Conn.get_session(conn, :chat_session_id) do
      nil ->
        session_id = "session-#{System.unique_integer([:positive])}"
        Plug.Conn.put_session(conn, :chat_session_id, session_id)

      _ ->
        conn
    end
  end

  scope "/", AgentExWeb do
    pipe_through(:browser)

    live("/", ChatLive, :index)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:agent_ex, :dev_routes, false) ||
       Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: AgentExWeb.Telemetry)
    end
  end
end
