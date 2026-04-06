defmodule AgentEx.DetsManager do
  @moduledoc """
  Per-project DETS lifecycle manager.

  Tracks open DETS handles in an ETS registry. Opens per-project DETS files
  lazily on first access and closes them on project eviction or deletion.

  Each project stores its DETS files under `root_path/.agent_ex/`:
    - agent_configs.dets
    - http_tool_configs.dets
    - persistent_memory.dets
    - procedural_memory.dets
  """

  use GenServer

  require Logger

  @store_names ~w(agent_configs http_tool_configs persistent_memory procedural_memory)a
  @registry_table :dets_manager_registry
  @project_paths_table :dets_manager_project_paths

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Open a per-project DETS file. Returns the DETS table reference.
  If already open, returns the existing handle.
  """
  def open(root_path, store_name) when store_name in @store_names do
    GenServer.call(__MODULE__, {:open, root_path, store_name})
  end

  @doc """
  Close a specific DETS file for a project.
  """
  def close(root_path, store_name) when store_name in @store_names do
    GenServer.call(__MODULE__, {:close, root_path, store_name})
  end

  @doc """
  Close all DETS files for a project.
  """
  def close_all(root_path) do
    GenServer.call(__MODULE__, {:close_all, root_path})
  end

  @doc """
  Returns the DETS table ref if already open, or nil.
  """
  def lookup(root_path, store_name) do
    case :ets.lookup(@registry_table, {root_path, store_name}) do
      [{_, dets_ref}] -> dets_ref
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns the filesystem path for a project's DETS file.
  """
  def path_for(root_path, store_name) do
    Path.join([Path.expand(root_path), ".agent_ex", "#{store_name}.dets"])
    |> String.to_charlist()
  end

  @doc """
  Returns all currently open {root_path, store_name} pairs.
  """
  def open_handles do
    :ets.tab2list(@registry_table)
  rescue
    ArgumentError -> []
  end

  @doc """
  Sync a specific open DETS table to disk.
  """
  def sync(root_path, store_name) do
    case lookup(root_path, store_name) do
      nil -> :ok
      dets_ref -> :dets.sync(dets_ref)
    end
  end

  @doc """
  Sync all open DETS tables for a project to disk.
  """
  def sync_all(root_path) do
    Enum.each(@store_names, fn store_name ->
      sync(root_path, store_name)
    end)
  end

  @doc """
  Register a project's root_path so stores can resolve it from {user_id, project_id}.
  Called during hydrate_project.
  """
  def register_project(user_id, project_id, root_path) do
    :ets.insert(@project_paths_table, {{user_id, project_id}, root_path})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Unregister a project's root_path mapping.
  """
  def unregister_project(user_id, project_id) do
    :ets.delete(@project_paths_table, {user_id, project_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Look up a project's root_path from {user_id, project_id}.
  Returns nil if not registered.
  """
  def root_path_for(user_id, project_id) do
    case :ets.lookup(@project_paths_table, {user_id, project_id}) do
      [{_, root_path}] -> root_path
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns all open root_paths (for sync_all iteration).
  """
  def registered_projects do
    :ets.tab2list(@project_paths_table)
  rescue
    ArgumentError -> []
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts) do
    ets =
      :ets.new(@registry_table, [:set, :named_table, :public, read_concurrency: true])

    :ets.new(@project_paths_table, [:set, :named_table, :public, read_concurrency: true])

    {:ok, %{ets: ets}}
  end

  @impl GenServer
  def handle_call({:open, root_path, store_name}, _from, state) do
    key = {root_path, store_name}

    case :ets.lookup(state.ets, key) do
      [{_, dets_ref}] ->
        {:reply, {:ok, dets_ref}, state}

      [] ->
        dets_path = path_for(root_path, store_name)
        dets_ref = :"dets_#{store_name}_#{:erlang.phash2(dets_path)}"

        case :dets.open_file(dets_ref, file: dets_path, type: :set) do
          {:ok, ^dets_ref} ->
            :ets.insert(state.ets, {key, dets_ref})
            {:reply, {:ok, dets_ref}, state}

          {:error, reason} ->
            Logger.error(
              "DetsManager: failed to open #{store_name} for #{root_path}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:close, root_path, store_name}, _from, state) do
    key = {root_path, store_name}

    case :ets.lookup(state.ets, key) do
      [{_, dets_ref}] ->
        :dets.sync(dets_ref)
        :dets.close(dets_ref)
        :ets.delete(state.ets, key)
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call({:close_all, root_path}, _from, state) do
    Enum.each(@store_names, fn store_name ->
      key = {root_path, store_name}

      case :ets.lookup(state.ets, key) do
        [{_, dets_ref}] ->
          :dets.sync(dets_ref)
          :dets.close(dets_ref)
          :ets.delete(state.ets, key)

        [] ->
          :ok
      end
    end)

    {:reply, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :ets.foldl(
      fn {_key, dets_ref}, :ok ->
        :dets.sync(dets_ref)
        :dets.close(dets_ref)
        :ok
      end,
      :ok,
      state.ets
    )

    :ok
  end
end
