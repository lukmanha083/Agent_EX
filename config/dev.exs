import Config

config :agent_ex,
  dets_dir: "priv/data/dev",
  # Dev-only vault key (32 bytes, base64). Generate for prod with:
  # :crypto.strong_rand_bytes(32) |> Base.encode64()
  vault_key: "EMSRIAOwy6s+d17xQGXfmo0RIFF0omVEvGah1nOkAQ0="

# Database
config :agent_ex, AgentEx.Repo,
  username: "agent_ex",
  password: "agent_ex_dev",
  hostname: "localhost",
  database: "agent_ex_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Dev server with live reload
config :agent_ex, AgentExWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-development-use",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:agent_ex, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:agent_ex, ~w(--watch)]}
  ]

# Live reload
config :agent_ex, AgentExWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/agent_ex_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Initialize plug at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

if File.exists?(Path.expand("dev.secret.exs", __DIR__)) do
  import_config "dev.secret.exs"
end
