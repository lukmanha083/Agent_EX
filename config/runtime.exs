import Config

config :agent_ex,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  moonshot_api_key: System.get_env("MOONSHOT_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  serpapi_api_key: System.get_env("SERPAPI_API_KEY"),
  helix_db_url: System.get_env("HELIX_DB_URL") || "http://localhost:6969"
