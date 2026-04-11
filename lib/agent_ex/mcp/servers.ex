defmodule AgentEx.MCP.Servers do
  @moduledoc """
  CRUD context for MCP server configurations.

  MCP servers are registered per-project and passed to the LLM API
  for server-side tool execution (Anthropic `mcp_servers` parameter).
  """

  import Ecto.Query

  alias AgentEx.MCP.ServerConfig
  alias AgentEx.Repo

  @doc "List all MCP servers for a project."
  def list(project_id) do
    from(s in ServerConfig,
      where: s.project_id == ^project_id,
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  @doc "List only enabled MCP servers for a project."
  def list_enabled(project_id) do
    from(s in ServerConfig,
      where: s.project_id == ^project_id and s.enabled == true,
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  @doc "Get a single MCP server by ID."
  def get(project_id, id) do
    Repo.get_by(ServerConfig, id: id, project_id: project_id)
  end

  @doc "Create a new MCP server config."
  def create(attrs) do
    %ServerConfig{}
    |> ServerConfig.changeset(attrs)
    |> Repo.insert()
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

  @doc "Toggle enabled/disabled for a server."
  def toggle(project_id, id) do
    case get(project_id, id) do
      nil ->
        {:error, :not_found}

      server ->
        update_server(server, %{enabled: not server.enabled})
    end
  end

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
