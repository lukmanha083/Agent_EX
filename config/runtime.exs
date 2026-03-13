import Config

config :agent_ex,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  helix_db_url: System.get_env("HELIX_DB_URL") || "http://localhost:6969"
