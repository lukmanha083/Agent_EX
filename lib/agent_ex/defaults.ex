defmodule AgentEx.Defaults do
  @moduledoc """
  Manages default (system) agents and tools.

  System agents are registered in Postgres at app boot — shared across all
  projects, read-only, with capability embeddings computed once.

  User agents are created per-project and can shadow system agents by name.

  ## Lifecycle

  Called from `Application.start/2` after Repo is ready:

      AgentEx.Defaults.register_system_agents()
  """

  alias AgentEx.{AgentConfig, AgentStore}
  alias AgentEx.Defaults.{Agents, Tools}

  require Logger

  @doc """
  Register all default agent templates as system agents in Postgres.

  Idempotent — uses upsert. Called once at app boot.
  Capability embeddings are computed asynchronously to avoid blocking startup.
  """
  def register_system_agents do
    Enum.each(Agents.templates(), fn template ->
      config =
        template
        |> Map.merge(%{
          user_id: 0,
          project_id: 0,
          provider: "anthropic",
          model: "claude-haiku-4-5-20251001"
        })
        |> AgentConfig.new()

      case AgentStore.save_system(config) do
        {:ok, _} ->
          Logger.info("Defaults: registered system agent '#{config.name}'")

        {:error, reason} ->
          Logger.warning("Defaults: failed to register '#{template.name}': #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  Seed user-owned copies of default agents into a project.

  Only seeds if the project has no user agents yet (idempotent).
  Unlike system agents, these are mutable — users can edit/delete them.

  Returns `:ok` if seeded, `:already_seeded` if project already has agents.
  """
  def seed_project(user_id, project_id, opts \\ []) do
    if AgentStore.list(user_id, project_id) == [] do
      provider = Keyword.get(opts, :provider, "anthropic")
      seed_agents(user_id, project_id, provider)
      seed_tools(user_id, project_id)
      :ok
    else
      :already_seeded
    end
  end

  defp seed_agents(user_id, project_id, provider) do
    model = AgentEx.ProviderHelpers.default_model_for(provider)

    Enum.each(Agents.templates(), fn template ->
      config =
        template
        |> Map.merge(%{
          user_id: user_id,
          project_id: project_id,
          provider: provider,
          model: model
        })
        |> AgentConfig.new()

      case AgentStore.save(config) do
        {:ok, _} ->
          Logger.info("Defaults: seeded agent '#{config.name}' for project #{project_id}")

        {:error, reason} ->
          Logger.warning("Defaults: failed to seed agent '#{template.name}': #{inspect(reason)}")
      end
    end)
  end

  defp seed_tools(user_id, project_id) do
    Enum.each(Tools.templates(), fn template ->
      tool =
        template
        |> Map.merge(%{user_id: user_id, project_id: project_id})
        |> AgentEx.HttpTool.new()

      case AgentEx.HttpToolStore.save(tool) do
        {:ok, _} ->
          Logger.info("Defaults: seeded tool '#{tool.name}' for project #{project_id}")

        {:error, reason} ->
          Logger.warning("Defaults: failed to seed tool '#{template.name}': #{inspect(reason)}")
      end
    end)
  end
end
