defmodule AgentEx.Projects do
  @moduledoc "Project context — CRUD and default project management."

  import Ecto.Query

  alias AgentEx.Projects.Project
  alias AgentEx.Repo

  require Logger

  def create_project(attrs) do
    with {:ok, project} <- %Project{} |> Project.changeset(attrs) |> Repo.insert() do
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
    |> order_by(asc: :is_default, asc: :name)
    |> Repo.all()
  end

  def update_project(%Project{} = project, attrs) do
    with {:ok, updated} <- project |> Project.changeset(attrs) |> Repo.update() do
      ensure_root_path_dir(updated)
      {:ok, updated}
    end
  end

  def delete_project(%Project{is_default: true}), do: {:error, :cannot_delete_default}

  def delete_project(%Project{} = project) do
    with {:ok, deleted} <- Repo.delete(project) do
      # Conversations + messages cascade via DB foreign key (on_delete: :delete_all)
      # Agent configs: remove from ETS/DETS
      AgentEx.AgentStore.delete_by_project(project.user_id, project.id)
      # Memory: all tiers scoped by (user_id, project_id) — direct project-scoped delete
      Task.start(fn -> AgentEx.Memory.delete_project_data(project.user_id, project.id) end)
      {:ok, deleted}
    end
  end

  @doc "Get or create the default project for a user. Safe under concurrent calls."
  def ensure_default_project(user_id) do
    case Repo.get_by(Project, user_id: user_id, is_default: true) do
      %Project{} = project -> {:ok, project}
      nil -> create_default_project(user_id)
    end
  end

  defp create_default_project(user_id) do
    case create_project(%{user_id: user_id, name: "Default", is_default: true}) do
      {:ok, project} ->
        {:ok, project}

      {:error, _changeset} ->
        # Race: another process created the default project concurrently
        case Repo.get_by(Project, user_id: user_id, is_default: true) do
          %Project{} = project -> {:ok, project}
          nil -> {:error, :default_project_creation_failed}
        end
    end
  end

  def get_default_project(user_id) do
    Repo.get_by(Project, user_id: user_id, is_default: true)
  end

  @doc """
  Auto-create the sandbox root directory if one is configured.
  Only runs in local mode — in bridge mode, the bridge handles this.
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
