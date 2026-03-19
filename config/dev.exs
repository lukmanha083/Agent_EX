import Config

config :agent_ex,
  dets_dir: "priv/data/dev"

if File.exists?(Path.expand("dev.secret.exs", __DIR__)) do
  import_config "dev.secret.exs"
end
