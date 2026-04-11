defmodule AgentEx.MCP.ServerConfig do
  @moduledoc """
  Ecto schema for MCP server configurations.

  Each project can have multiple MCP servers registered. When enabled,
  these are passed to the Anthropic API as `mcp_servers` so Claude can
  call them directly during inference (server-side execution).
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

    timestamps()
  end

  @required_fields [:name, :url, :project_id]
  @optional_fields [:description, :provider, :enabled, :auth_token_key, :tools_filter]

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
