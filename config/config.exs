import Config

config :agent_ex,
  helix_db_url: "http://localhost:6969",
  embedding_model: "text-embedding-3-small",
  embedding_dimensions: 1536,
  extraction_model: "gpt-4o-mini",
  persistent_memory_sync_interval: :timer.seconds(30),
  working_memory_max_messages: 50

import_config "#{config_env()}.exs"
