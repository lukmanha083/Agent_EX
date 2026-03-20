import Config

config :agent_ex,
  helix_db_url: "http://localhost:6969",
  embedding_model: "text-embedding-3-small",
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

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
