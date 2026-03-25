defmodule AgentExWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agent_ex

  # 15-minute idle timeout: Plug.Session only re-sends Set-Cookie when
  # session data changes, so we touch :_last_active in user_auth to
  # ensure the cookie is refreshed on every authenticated request.
  @session_options [
    store: :cookie,
    key: "_agent_ex_key",
    signing_salt: "agent_ex_salt",
    same_site: "Lax",
    max_age: 15 * 60
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  if Application.compile_env(:agent_ex, :sql_sandbox) do
    plug(Phoenix.Ecto.SQL.Sandbox)
  end

  plug(Plug.Static,
    at: "/",
    from: :agent_ex,
    gzip: false,
    only: AgentExWeb.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(AgentExWeb.Router)
end
