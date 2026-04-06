defmodule AgentEx.Projects do
  @moduledoc "Project context — CRUD for user projects."

  import Ecto.Query

  alias AgentEx.Projects.Project
  alias AgentEx.Repo

  require Logger

  def create_project(attrs) do
    Repo.transaction(fn ->
      project = insert_project!(attrs)
      scaffold_or_rollback(project)
      project
    end)
  end

  defp insert_project!(attrs) do
    case %Project{} |> Project.creation_changeset(attrs) |> Repo.insert() do
      {:ok, project} -> project
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp scaffold_or_rollback(project) do
    with :ok <- ensure_root_path_dir(project),
         :ok <- scaffold_project_dirs(project) do
      :ok
    else
      {:error, reason} -> Repo.rollback({:scaffold_failed, reason})
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
      # 1. Unregister first — prevents concurrent writes from re-opening DETS
      AgentEx.DetsManager.unregister_project(project.user_id, project.id)

      # 2. Evict project data from ETS
      AgentEx.AgentStore.evict_project(project.user_id, project.id)
      AgentEx.HttpToolStore.evict_project(project.user_id, project.id)
      AgentEx.Memory.PersistentMemory.Store.evict_project(project.user_id, project.id)
      AgentEx.Memory.ProceduralMemory.Store.evict_project(project.user_id, project.id)

      # 3. Close all DETS handles
      if project.root_path && project.root_path != "" do
        AgentEx.DetsManager.close_all(project.root_path)
      end

      # 4. Delete the .agent_ex directory — all DETS data gone instantly
      if project.root_path && project.root_path != "" do
        agent_ex_dir = Path.join(Path.expand(project.root_path), ".agent_ex")
        File.rm_rf(agent_ex_dir)
      end

      # Workflows, SemanticMemory, KG episodes: ON DELETE CASCADE from projects table
      # Explicit cleanup ensures Tier 1 sessions are stopped and ETS is cleared
      schedule_memory_cleanup(project)
      {:ok, deleted}
    end
  end

  defp schedule_memory_cleanup(project) do
    cleanup_fn = fn ->
      try do
        AgentEx.Memory.delete_project_data(project.user_id, project.id)
      rescue
        e ->
          Logger.error(
            "Failed to delete memory data for project #{project.id}: #{Exception.message(e)}"
          )
      end
    end

    case Task.Supervisor.start_child(AgentEx.TaskSupervisor, cleanup_fn) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to schedule memory cleanup for project #{project.id}: #{inspect(reason)}"
        )

        cleanup_fn.()
    end
  end

  defp scaffold_project_dirs(%Project{root_path: root_path})
       when is_binary(root_path) and root_path != "" do
    expanded = Path.expand(root_path)
    agent_ex_dir = Path.join(expanded, ".agent_ex")
    memory_dir = Path.join(expanded, ".memory")

    with :ok <- File.mkdir_p(agent_ex_dir),
         :ok <- File.mkdir_p(memory_dir) do
      gitignore_path = Path.join(agent_ex_dir, ".gitignore")

      unless File.exists?(gitignore_path) do
        File.write(gitignore_path, "# AgentEx project data — do not commit\n*.dets\n")
      end

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to scaffold project dirs for #{expanded}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp scaffold_project_dirs(_), do: :ok

  @doc """
  Check if a project's root_path exists on this machine.
  Returns false if root_path is nil/empty or the directory doesn't exist.
  """
  def project_available?(%Project{root_path: root_path})
      when is_binary(root_path) and root_path != "" do
    File.dir?(Path.expand(root_path))
  end

  def project_available?(_), do: false

  @doc """
  Hydrate all DETS-backed stores for a project. Called on first project access.
  Registers the project's root_path in DetsManager and loads DETS data into ETS.

  Returns `:ok` on success, `:unavailable` if root_path doesn't exist on this machine.
  """
  def hydrate_project(%Project{} = project) do
    root_path = project.root_path

    cond do
      is_nil(root_path) or root_path == "" ->
        :unavailable

      not project_available?(project) ->
        :unavailable

      AgentEx.DetsManager.root_path_for(project.user_id, project.id) != nil ->
        :ok

      true ->
        AgentEx.DetsManager.register_project(project.user_id, project.id, root_path)

        with :ok <- scaffold_project_dirs(project),
             {:ok, _} <- AgentEx.AgentStore.hydrate_project(root_path),
             {:ok, _} <- AgentEx.HttpToolStore.hydrate_project(root_path),
             {:ok, _} <- AgentEx.Memory.PersistentMemory.Store.hydrate_project(root_path),
             {:ok, _} <- AgentEx.Memory.ProceduralMemory.Store.hydrate_project(root_path) do
          AgentEx.Defaults.seed_project(project.user_id, project.id, provider: project.provider)
          :ok
        else
          {:error, reason} ->
            Logger.warning("Failed to hydrate project #{project.id}: #{inspect(reason)}")
            AgentEx.DetsManager.unregister_project(project.user_id, project.id)
            :unavailable
        end
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
