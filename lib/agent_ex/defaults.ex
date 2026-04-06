defmodule AgentEx.Defaults do
  @moduledoc """
  Orchestrates seeding of default agents and tools into new projects.

  Templates are defined in `AgentEx.Defaults.Agents` and `AgentEx.Defaults.Tools`.
  On first project hydration, copies are created in the project's DETS stores.
  After seeding, copies are user-owned — they can be modified or deleted freely.

  ## Usage

  Called automatically from `Projects.hydrate_project/1`:

      AgentEx.Defaults.seed_project(user_id, project_id, provider: "anthropic")
  """

  alias AgentEx.{AgentConfig, AgentStore, HttpTool, HttpToolStore}
  alias AgentEx.Defaults.{Agents, Tools}

  require Logger

  @doc """
  Seed default agents and tools into a project's stores.

  Only seeds if the project has no agents yet (idempotent).
  Uses the project's provider to select the appropriate model.

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
        |> HttpTool.new()

      case HttpToolStore.save(tool) do
        {:ok, _} ->
          Logger.info("Defaults: seeded tool '#{tool.name}' for project #{project_id}")

        {:error, reason} ->
          Logger.warning("Defaults: failed to seed tool '#{template.name}': #{inspect(reason)}")
      end
    end)
  end
end
