defmodule AgentEx.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    belongs_to(:user, AgentEx.Accounts.User)
    has_many(:conversations, AgentEx.Chat.Conversation)

    field(:name, :string)
    field(:description, :string)
    field(:root_path, :string)
    field(:is_default, :boolean, default: false)
    field(:provider, :string)
    field(:model, :string)
    field(:disabled_builtins, {:array, :string}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a new project. Provider and model are required and locked after creation."
  def creation_changeset(project, attrs) do
    project
    |> cast(attrs, [
      :user_id,
      :name,
      :description,
      :root_path,
      :provider,
      :model,
      :disabled_builtins
    ])
    |> validate_required([:user_id, :name, :provider, :model])
    |> validate_inclusion(:provider, AgentEx.ProviderHelpers.valid_providers())
    |> validate_model_for_provider()
    |> unique_constraint([:user_id, :name])
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for updating an existing project. Provider and model cannot be changed."
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :description, :root_path, :disabled_builtins])
    |> validate_required([:name])
    |> unique_constraint([:user_id, :name])
  end

  # Keep for backwards compat with existing default project logic (removed in Phase 2)
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :user_id,
      :name,
      :description,
      :root_path,
      :is_default,
      :provider,
      :model,
      :disabled_builtins
    ])
    |> validate_required([:user_id, :name])
    |> unique_constraint([:user_id, :name])
    |> unique_constraint(:is_default, name: :projects_one_default_per_user)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_model_for_provider(changeset) do
    provider = get_field(changeset, :provider)
    model = get_field(changeset, :model)

    if provider && model && not AgentEx.ProviderHelpers.valid_model?(provider, model) do
      add_error(changeset, :model, "is not valid for the selected provider")
    else
      changeset
    end
  end
end
