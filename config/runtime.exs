import Config

# Only override config when env vars are actually set,
# so dev.secret.exs values aren't clobbered with nil.
for {env_var, config_key} <- [
      {"OPENAI_API_KEY", :openai_api_key},
      {"MOONSHOT_API_KEY", :moonshot_api_key},
      {"ANTHROPIC_API_KEY", :anthropic_api_key},
      {"SERPAPI_API_KEY", :serpapi_api_key}
    ] do
  if value = System.get_env(env_var) do
    config :agent_ex, [{config_key, value}]
  end
end

if helix_url = System.get_env("HELIX_DB_URL") do
  config :agent_ex, helix_db_url: helix_url
end

# Phoenix runtime config
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE env var is required in production"

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PHX_PORT") || "4000")

  config :agent_ex, AgentExWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
