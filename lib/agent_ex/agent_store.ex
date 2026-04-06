defmodule AgentEx.AgentStore do
  @moduledoc """
  ETS + per-project DETS persistence for agent configs.
  ETS for fast reads, DETS files under each project's `root_path/.agent_ex/` for disk persistence.
  Keys are `{user_id, project_id, agent_id}` for per-user, per-project isolation.

  DETS files are opened lazily on first project access (not at boot) via DetsManager.
  """

  use GenServer

  alias AgentEx.AgentConfig
  alias AgentEx.DetsManager

  require Logger

  @store_name :agent_configs

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Save an agent config (insert or update)."
  def save(%AgentConfig{} = config) do
    GenServer.call(__MODULE__, {:save, config})
  end

  @doc "Get a specific agent config by user_id, project_id, and agent_id."
  def get(user_id, project_id, agent_id) do
    case :ets.lookup(@store_name, {user_id, project_id, agent_id}) do
      [{{^user_id, ^project_id, ^agent_id}, config}] -> {:ok, config}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "List all agent configs for a user within a project."
  def list(user_id, project_id) do
    pattern = {{user_id, project_id, :_}, :"$1"}

    :ets.match(@store_name, pattern)
    |> List.flatten()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  rescue
    ArgumentError -> []
  end

  @doc "Delete an agent config."
  def delete(user_id, project_id, agent_id) do
    GenServer.call(__MODULE__, {:delete, user_id, project_id, agent_id})
  end

  @doc """
  Hydrate a project's data from its DETS file into ETS.
  Called on first project access (e.g. when user selects a project).
  """
  def hydrate_project(root_path) do
    GenServer.call(__MODULE__, {:hydrate_project, root_path})
  end

  @doc """
  Evict a project's data from ETS. Called on project deletion or idle timeout.
  """
  def evict_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:evict_project, user_id, project_id})
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts) do
    sync_interval =
      Application.get_env(:agent_ex, :agent_store_sync_interval, :timer.seconds(30))

    ets_table =
      :ets.new(@store_name, [:set, :named_table, :public, read_concurrency: true])

    schedule_sync(sync_interval)

    {:ok, %{ets_table: ets_table, sync_interval: sync_interval}}
  end

  @impl GenServer
  def handle_call({:save, %AgentConfig{} = config}, _from, state) do
    key = {config.user_id, config.project_id, config.id}
    root_path = DetsManager.root_path_for(config.user_id, config.project_id)

    if root_path do
      case ensure_dets_and_insert(root_path, key, config) do
        :ok ->
          :ets.insert(state.ets_table, {key, config})
          {:reply, {:ok, config}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      # No root_path registered — ETS-only (should not happen in normal flow)
      Logger.warning("AgentStore: no root_path for project #{config.project_id}, ETS-only save")
      :ets.insert(state.ets_table, {key, config})
      {:reply, {:ok, config}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete, user_id, project_id, agent_id}, _from, state) do
    key = {user_id, project_id, agent_id}
    root_path = DetsManager.root_path_for(user_id, project_id)

    if root_path do
      case resolve_dets(root_path) do
        {:ok, dets_ref} -> :dets.delete(dets_ref, key)
        _ -> :ok
      end
    end

    :ets.delete(state.ets_table, key)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:hydrate_project, root_path}, _from, state) do
    case DetsManager.open(root_path, @store_name) do
      {:ok, dets_ref} ->
        count =
          :dets.foldl(
            fn {key, value}, acc ->
              :ets.insert(state.ets_table, {key, value})
              acc + 1
            end,
            0,
            dets_ref
          )

        Logger.info("AgentStore: hydrated #{count} agent configs for #{root_path}")
        {:reply, {:ok, count}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:evict_project, user_id, project_id}, _from, state) do
    keys =
      :ets.foldl(
        fn
          {{^user_id, ^project_id, _} = key, _}, acc -> [key | acc]
          _, acc -> acc
        end,
        [],
        state.ets_table
      )

    Enum.each(keys, fn key -> :ets.delete(state.ets_table, key) end)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    sync_all_projects(state.ets_table)
    schedule_sync(state.sync_interval)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    sync_all_projects(state.ets_table)
    :ok
  end

  # --- Private helpers ---

  defp ensure_dets_and_insert(root_path, key, value) do
    case resolve_dets(root_path) do
      {:ok, dets_ref} -> :dets.insert(dets_ref, {key, value})
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_dets(root_path) do
    case DetsManager.lookup(root_path, @store_name) do
      nil -> DetsManager.open(root_path, @store_name)
      dets_ref -> {:ok, dets_ref}
    end
  end

  defp sync_all_projects(ets_table) do
    DetsManager.registered_projects()
    |> Enum.each(fn {{_user_id, _project_id}, root_path} ->
      sync_project(ets_table, root_path)
    end)
  end

  defp sync_project(ets_table, root_path) do
    case DetsManager.lookup(root_path, @store_name) do
      nil -> :ok
      dets_ref -> sync_ets_to_dets(ets_table, dets_ref, root_path)
    end
  end

  defp sync_ets_to_dets(ets_table, dets_ref, root_path) do
    project_keys = projects_for_root_path(root_path)

    :ets.foldl(
      fn {{u, p, _} = key, value}, :ok ->
        if MapSet.member?(project_keys, {u, p}) do
          :dets.insert(dets_ref, {key, value})
        end

        :ok
      end,
      :ok,
      ets_table
    )

    :dets.sync(dets_ref)
  end

  defp projects_for_root_path(root_path) do
    DetsManager.registered_projects()
    |> Enum.filter(fn {_, rp} -> rp == root_path end)
    |> Enum.map(fn {key, _} -> key end)
    |> MapSet.new()
  end

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
