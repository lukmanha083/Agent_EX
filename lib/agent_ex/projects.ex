defmodule AgentEx.Projects do
  @moduledoc "Project context — CRUD and default project management."

  import Ecto.Query

  alias AgentEx.Projects.Project
  alias AgentEx.Repo

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def get_user_project(user_id, project_id) do
    Repo.get_by(Project, id: project_id, user_id: user_id)
  end

  def list_projects(user_id) do
    Project
    |> where(user_id: ^user_id)
    |> order_by(asc: :is_default, asc: :name)
    |> Repo.all()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def delete_project(%Project{is_default: true}), do: {:error, :cannot_delete_default}

  def delete_project(%Project{} = project), do: Repo.delete(project)

  @doc "Get or create the default project for a user."
  def ensure_default_project(user_id) do
    case Repo.get_by(Project, user_id: user_id, is_default: true) do
      %Project{} = project ->
        {:ok, project}

      nil ->
        create_project(%{user_id: user_id, name: "Default", is_default: true})
    end
  end

  def get_default_project(user_id) do
    Repo.get_by(Project, user_id: user_id, is_default: true)
  end
end
