defmodule AgentEx.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    belongs_to(:user, AgentEx.Accounts.User)
    has_many(:conversations, AgentEx.Chat.Conversation)

    field(:name, :string)
    field(:description, :string)
    field(:root_path, :string)
    field(:provider, :string)
    field(:model, :string)
    field(:disabled_builtins, {:array, :string}, default: [])
    field(:token_budget, :integer)

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
      :disabled_builtins,
      :token_budget
    ])
    |> validate_required([:user_id, :name, :provider, :model])
    |> validate_root_path()
    |> validate_inclusion(:provider, AgentEx.ProviderHelpers.valid_providers())
    |> validate_model_for_provider()
    |> unique_constraint([:user_id, :name])
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for updating an existing project. Provider and model cannot be changed."
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :description, :root_path, :disabled_builtins, :token_budget])
    |> validate_required([:name])
    |> validate_root_path()
    |> validate_number(:token_budget, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :name])
  end

  defp validate_root_path(changeset) do
    case get_change(changeset, :root_path) do
      nil ->
        changeset

      path when is_binary(path) ->
        cond do
          String.contains?(path, "~") ->
            add_error(changeset, :root_path, "must be an absolute path (no ~ allowed), e.g. /home/user/project")

          not String.starts_with?(path, "/") ->
            add_error(changeset, :root_path, "must be an absolute path starting with /")

          true ->
            changeset
        end
    end
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
