import Config

config :agent_ex,
  dets_dir: "priv/data/test",
  persistent_memory_sync_interval: :timer.seconds(1)

# Disable the web server in tests
config :agent_ex, AgentExWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-testing-purposes",
  server: false
