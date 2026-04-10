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
  alias AgentEx.MCP.Servers, as: McpServers

  require Logger

  @doc """
  Register all default agent templates as system agents in Postgres.

  Idempotent — uses upsert. Called once at app boot (async via TaskSupervisor).
  Capability embeddings are computed separately via CapabilityIndex.
  """
  def register_system_agents do
    Enum.each(Agents.templates(), fn template ->
      config =
        template
        |> Map.put_new(:provider, "anthropic")
        |> Map.put_new(:model, "claude-haiku-4-5-20251001")
        |> Map.merge(%{user_id: 0, project_id: 0})
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
  Seed default tools into a project.

  Seeds HTTP tools (project-scoped). System agents are shared globally
  and don't require per-project seeding.

  Returns `:ok`.
  """
  def seed_project(user_id, project_id, _opts \\ []) do
    # System agents are shared globally — no per-project agent seeding needed.
    seed_tools(user_id, project_id)
    seed_mcp_servers(project_id)
    :ok
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

  @mcp_server_templates [
    %{
      name: "context7",
      description:
        "Library documentation lookup — resolve library IDs and query current docs for any framework or package",
      url: "https://mcp.context7.com/sse",
      provider: "anthropic"
    },
    %{
      name: "fetch",
      description: "Web content fetching — retrieve and extract content from URLs",
      url: "https://mcp.anthropic.com/fetch/sse",
      provider: "anthropic"
    }
  ]

  defp seed_mcp_servers(project_id) do
    Enum.each(@mcp_server_templates, fn template ->
      attrs =
        template
        |> Map.put(:project_id, project_id)
        |> Map.put(:enabled, true)

      case McpServers.create(attrs) do
        {:ok, _} ->
          Logger.info("Defaults: seeded MCP server '#{template.name}' for project #{project_id}")

        {:error, %Ecto.Changeset{}} ->
          # Unique constraint (already exists) — skip
          :ok

        {:error, reason} ->
          Logger.warning(
            "Defaults: failed to seed MCP server '#{template.name}': #{inspect(reason)}"
          )
      end
    end)
  end
end
