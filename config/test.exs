import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

config :agent_ex,
  dets_dir: "priv/data/test",
  persistent_memory_sync_interval: :timer.seconds(1)

# Test database (use sandbox for concurrent tests)
config :agent_ex, AgentEx.Repo,
  username: "agent_ex",
  password: "agent_ex_dev",
  hostname: "localhost",
  database: "agent_ex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Enable the web server for Wallaby browser tests
config :agent_ex, AgentExWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-testing-purposes",
  server: true

# Allow Wallaby to share the Ecto sandbox with browser requests
config :agent_ex, :sql_sandbox, true

# Wallaby browser test configuration
config :wallaby,
  otp_app: :agent_ex,
  base_url: "http://localhost:4002",
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  chrome: [
    headless: true
  ]
