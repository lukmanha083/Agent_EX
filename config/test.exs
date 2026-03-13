import Config

config :agent_ex,
  dets_dir: "priv/data/test",
  persistent_memory_sync_interval: :timer.seconds(1)
