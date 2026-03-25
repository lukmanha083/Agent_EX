defmodule AgentEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {AgentEx.Application, []}
    ]
  end

  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},

      # Timezone
      {:tz, "~> 0.28"},

      # Database
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},

      # Phoenix
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_ecto, "~> 4.6"},
      {:swoosh, "~> 1.17"},
      {:bandit, "~> 1.6"},
      {:phoenix_live_dashboard, "~> 0.8"},

      # UI Components
      {:salad_ui, "~> 1.0.0-beta.3"},

      # Assets
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},

      # Dev/Test
      {:wallaby, "~> 0.30", only: :test, runtime: false},
      {:lazy_html, "~> 0.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind agent_ex", "esbuild agent_ex"],
      "assets.deploy": [
        "tailwind agent_ex --minify",
        "esbuild agent_ex --minify",
        "phx.digest"
      ]
    ]
  end
end
