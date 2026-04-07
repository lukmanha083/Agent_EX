import Config

# Production database + Phoenix config
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL env var is required in production"

  config :agent_ex, AgentEx.Repo,
    url: database_url,
    types: AgentEx.PostgrexTypes,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE env var is required in production"

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST env var is required in production"

  port = String.to_integer(System.get_env("PHX_PORT") || "4000")

  live_view_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      raise "LIVE_VIEW_SIGNING_SALT env var is required in production (generate with: mix phx.gen.secret 32)"

  vault_key =
    System.get_env("VAULT_KEY") ||
      raise "VAULT_KEY env var is required in production (generate with: :crypto.strong_rand_bytes(32) |> Base.encode64())"

  config :agent_ex, vault_key: vault_key

  config :agent_ex, AgentExWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_salt]
end
