defmodule AgentExWeb.Router do
  use AgentExWeb, :router

  import AgentExWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AgentExWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_scope_for_user)
  end

  scope "/", AgentExWeb do
    pipe_through([:browser])

    live_session :authenticated,
      root_layout: {AgentExWeb.Layouts, :auth},
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
      live("/chat/:conversation_id", ChatLive, :show)
      live("/agents", AgentsLive, :index)
      live("/tools", ToolsLive, :index)

      live("/users/profile", UserLive.Profile, :edit)
      live("/users/profile/confirm-email/:token", UserLive.Profile, :confirm_email)
      live("/users/settings", UserLive.Settings, :edit)
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
