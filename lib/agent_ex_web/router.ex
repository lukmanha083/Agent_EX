defmodule AgentExWeb.Router do
  use AgentExWeb, :router

  import AgentExWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:ensure_chat_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AgentExWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_scope_for_user)
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
    pipe_through([:browser])

    live_session :authenticated,
      on_mount: [{AgentExWeb.UserAuth, :mount_current_scope}] do
      live("/", HomeLive, :index)
    end
  end

  # Enable LiveDashboard and Swoosh mailbox in development
  if Application.compile_env(:agent_ex, :dev_routes, false) ||
       Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: AgentExWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  ## Authentication routes

  scope "/", AgentExWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user,
      on_mount: [{AgentExWeb.UserAuth, :require_authenticated}] do
      live("/chat", ChatLive, :index)
      live("/users/settings", UserLive.Settings, :edit)
      live("/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email)
    end

    post("/users/update-password", UserSessionController, :update_password)
  end

  scope "/", AgentExWeb do
    pipe_through([:browser])

    live_session :current_user,
      root_layout: {AgentExWeb.Layouts, :auth},
      on_mount: [{AgentExWeb.UserAuth, :mount_current_scope}] do
      live("/users/register", UserLive.Registration, :new)
      live("/users/log-in", UserLive.Login, :new)
      live("/users/log-in/:token", UserLive.Confirmation, :new)
    end

    post("/users/log-in", UserSessionController, :create)
    delete("/users/log-out", UserSessionController, :delete)
  end
end
