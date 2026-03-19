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
