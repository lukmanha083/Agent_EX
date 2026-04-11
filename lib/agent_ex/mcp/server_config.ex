defmodule AgentEx.MCP.ServerConfig do
  @moduledoc """
  Ecto schema for MCP server configurations.

  System servers (system: true) are shared globally — registered at app boot.
  User servers (system: false) are per-project and can be added/edited/deleted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "mcp_servers" do
    field(:project_id, :integer)
    field(:name, :string)
    field(:description, :string)
    field(:url, :string)
    field(:provider, :string, default: "anthropic")
    field(:enabled, :boolean, default: true)
    field(:auth_token_key, :string)
    field(:tools_filter, {:array, :string}, default: [])
    field(:system, :boolean, default: false)

    timestamps()
  end

  @required_fields [:name, :url]
  @optional_fields [
    :project_id,
    :description,
    :provider,
    :enabled,
    :auth_token_key,
    :tools_filter,
    :system
  ]

  def changeset(server, attrs) do
    server
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:url, ~r/^https?:\/\//, message: "must start with http:// or https://")
    # Only Anthropic supports server-side MCP (mcp_servers API parameter)
    |> validate_inclusion(:provider, ["anthropic"])
    |> unique_constraint(:name,
      name: :mcp_servers_project_id_name_index,
      message: "already exists in this project"
    )
    |> unique_constraint(:name,
      name: :mcp_servers_system_name_index,
      message: "system server with this name already exists"
    )
    |> put_id()
  end

  defp put_id(%{data: %{id: nil}} = changeset) do
    put_change(changeset, :id, generate_id())
  end

  defp put_id(changeset), do: changeset

  defp generate_id do
    "mcp-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
  end
end
