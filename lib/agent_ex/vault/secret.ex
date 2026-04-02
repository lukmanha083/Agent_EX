defmodule AgentEx.Vault.Secret do
  use Ecto.Schema
  import Ecto.Changeset

  schema "project_secrets" do
    belongs_to(:project, AgentEx.Projects.Project)

    field(:key, :string)
    field(:encrypted_value, :binary)
    field(:value, :string, virtual: true, redact: true)
    field(:label, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:project_id, :key, :encrypted_value, :label])
    |> validate_required([:project_id, :key, :encrypted_value])
    |> validate_format(:key, ~r/^[a-z][a-z0-9_:.-]{0,63}$/,
      message:
        "must start with a letter and contain only lowercase, digits, underscores, colons, dots, hyphens"
    )
    |> unique_constraint([:project_id, :key])
    |> foreign_key_constraint(:project_id)
  end
end
