import Config

# Timezone database for Elixir's Calendar system
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :agent_ex, :scopes,
  user: [
    default: true,
    module: AgentEx.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: AgentEx.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :agent_ex,
  ecto_repos: [AgentEx.Repo],
  embedding_model: "text-embedding-3-large",
  embedding_dimensions: 1536,
  extraction_model: "gpt-4o-mini",
  persistent_memory_sync_interval: :timer.seconds(30),
  working_memory_max_messages: 50

# Phoenix endpoint
config :agent_ex, AgentExWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AgentExWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: AgentEx.PubSub,
  live_view: [signing_salt: "agent_ex_lv"]

# esbuild
config :esbuild,
  version: "0.21.5",
  agent_ex: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# tailwind
config :tailwind,
  version: "3.4.17",
  agent_ex: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Mailer (local dev adapter — emails shown at /dev/mailbox)
config :agent_ex, AgentEx.Mailer, adapter: Swoosh.Adapters.Local

# Swoosh API client — disable HTTP client (we use local adapter in dev)
config :swoosh, :api_client, false

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# SaladUI component library
config :salad_ui, color_scheme: :default

import_config "#{config_env()}.exs"
