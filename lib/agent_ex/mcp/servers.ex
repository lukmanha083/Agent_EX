defmodule AgentEx.MCP.Servers do
  @moduledoc """
  CRUD context for MCP server configurations.

  System servers (shared globally, registered at app boot) + user servers
  (per-project) are merged for API config and UI display.
  """

  import Ecto.Query

  alias AgentEx.MCP.ServerConfig
  alias AgentEx.Repo

  require Logger

  # -- Listing --

  @doc """
  List all MCP servers for a project (user + system, deduplicated by name).

  User servers are listed first, so a user server with the same name as a
  system server will shadow (override) the system entry.
  """
  def list_all(project_id) do
    user_servers = list_user(project_id)
    system_servers = list_system()
    Enum.uniq_by(user_servers ++ system_servers, & &1.name)
  end

  @doc "List user-created MCP servers for a project."
  def list_user(project_id) do
    from(s in ServerConfig,
      where: s.project_id == ^project_id and s.system == false,
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  @doc "List system (global default) MCP servers."
  def list_system do
    from(s in ServerConfig,
      where: s.system == true,
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  @doc "List only enabled MCP servers for API config (user + system)."
  def list_enabled(project_id) do
    user_servers =
      from(s in ServerConfig,
        where: s.project_id == ^project_id and s.system == false and s.enabled == true,
        order_by: [asc: s.name]
      )
      |> Repo.all()

    system_servers =
      from(s in ServerConfig,
        where: s.system == true and s.enabled == true,
        order_by: [asc: s.name]
      )
      |> Repo.all()

    Enum.uniq_by(user_servers ++ system_servers, & &1.name)
  end

  # -- CRUD --

  @doc "Get a single MCP server by ID."
  def get(id) do
    Repo.get(ServerConfig, id)
  end

  @doc "Create a new MCP server config."
  def create(attrs) do
    %ServerConfig{}
    |> ServerConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Save a system MCP server (upsert by name)."
  def save_system(attrs) do
    attrs =
      attrs
      |> Map.put(:system, true)
      |> Map.put(:project_id, nil)

    %ServerConfig{}
    |> ServerConfig.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :name, :inserted_at]},
      conflict_target: {:unsafe_fragment, "(name) WHERE system = true"}
    )
  end

  @doc "Update an existing MCP server config."
  def update_server(%ServerConfig{} = server, attrs) do
    server
    |> ServerConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete an MCP server config."
  def delete(%ServerConfig{} = server) do
    Repo.delete(server)
  end

  @doc "Toggle enabled/disabled for a project-owned, non-system server."
  def toggle(id, project_id) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %{system: true} ->
        {:error, :system_protected}

      %{project_id: pid} when pid != project_id ->
        {:error, :not_found}

      server ->
        update_server(server, %{enabled: not server.enabled})
    end
  end

  # -- API Config --

  @doc """
  Build the mcp_servers config for the Anthropic API.

  Returns a list of server maps ready to pass to ModelClient.create
  as the `mcp_servers` option. Resolves auth tokens from Vault.
  """
  def build_api_config(project_id) do
    list_enabled(project_id)
    |> Enum.map(fn server ->
      token = resolve_auth_token(project_id, server.auth_token_key)

      config = %{
        "type" => "url",
        "name" => server.name,
        "url" => server.url
      }

      if token, do: Map.put(config, "authorization_token", token), else: config
    end)
  end

  defp resolve_auth_token(_project_id, nil), do: nil
  defp resolve_auth_token(_project_id, ""), do: nil

  defp resolve_auth_token(project_id, key) do
    case AgentEx.Vault.resolve_key(project_id, key) do
      "" -> nil
      token -> token
    end
  end
end
