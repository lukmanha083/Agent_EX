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

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:user_id, :name, :description, :root_path, :is_default])
    |> validate_required([:user_id, :name])
    |> unique_constraint([:user_id, :name])
    |> unique_constraint(:is_default, name: :projects_one_default_per_user)
    |> foreign_key_constraint(:user_id)
  end
end
