defmodule AgentEx.Projects do
  @moduledoc "Project context — CRUD for user projects."

  import Ecto.Query

  alias AgentEx.Projects.Project
  alias AgentEx.Repo

  require Logger

  def create_project(attrs) do
    with {:ok, project} <- %Project{} |> Project.creation_changeset(attrs) |> Repo.insert() do
      ensure_root_path_dir(project)
      {:ok, project}
    end
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def get_user_project(user_id, project_id) do
    Repo.get_by(Project, id: project_id, user_id: user_id)
  end

  def list_projects(user_id) do
    Project
    |> where(user_id: ^user_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  def update_project(%Project{} = project, attrs) do
    with {:ok, updated} <- project |> Project.update_changeset(attrs) |> Repo.update() do
      ensure_root_path_dir(updated)
      {:ok, updated}
    end
  end

  def delete_project(%Project{} = project) do
    with {:ok, deleted} <- Repo.delete(project) do
      AgentEx.AgentStore.delete_by_project(project.user_id, project.id)
      AgentEx.HttpToolStore.delete_by_project(project.user_id, project.id)

      Task.Supervisor.start_child(AgentEx.TaskSupervisor, fn ->
        try do
          AgentEx.Memory.delete_project_data(project.user_id, project.id)
        rescue
          e ->
            Logger.error(
              "Failed to delete memory data for project #{project.id}: #{Exception.message(e)}"
            )
        end
      end)

      {:ok, deleted}
    end
  end

  @doc """
  Auto-create the sandbox root directory if one is configured.
  Safe: mkdir_p is a no-op if the directory already exists.
  """
  def ensure_root_path_dir(%Project{root_path: path}) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    case File.mkdir_p(expanded) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create project root_path #{expanded}: #{inspect(reason)}")
        {:error, {:root_path_creation_failed, reason}}
    end
  end

  def ensure_root_path_dir(_), do: :ok
end
