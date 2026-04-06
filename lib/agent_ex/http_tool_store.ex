defmodule AgentEx.HttpToolStore do
  @moduledoc """
  ETS + per-project DETS persistence for HTTP tool configs.
  Same pattern as AgentStore — ETS for fast reads, per-project DETS for disk persistence.
  Keys are `{user_id, project_id, tool_id}` for per-user, per-project isolation.
  """

  use GenServer

  alias AgentEx.DetsManager
  alias AgentEx.HttpTool

  require Logger

  @store_name :http_tool_configs

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Save an HTTP tool config (insert or update)."
  def save(%HttpTool{} = config) do
    GenServer.call(__MODULE__, {:save, config})
  end

  @doc "Get a specific HTTP tool config by user_id, project_id, and tool_id."
  def get(user_id, project_id, tool_id) do
    case :ets.lookup(@store_name, {user_id, project_id, tool_id}) do
      [{{^user_id, ^project_id, ^tool_id}, config}] -> {:ok, config}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "List all HTTP tool configs for a user within a project."
  def list(user_id, project_id) do
    pattern = {{user_id, project_id, :_}, :"$1"}

    :ets.match(@store_name, pattern)
    |> List.flatten()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  rescue
    ArgumentError -> []
  end

  @doc "Delete an HTTP tool config."
  def delete(user_id, project_id, tool_id) do
    GenServer.call(__MODULE__, {:delete, user_id, project_id, tool_id})
  end

  @doc "Hydrate a project's HTTP tool data from DETS into ETS."
  def hydrate_project(root_path) do
    GenServer.call(__MODULE__, {:hydrate_project, root_path})
  end

  @doc "Evict a project's data from ETS."
  def evict_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:evict_project, user_id, project_id})
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts) do
    sync_interval =
      Application.get_env(:agent_ex, :http_tool_store_sync_interval, :timer.seconds(30))

    ets_table =
      :ets.new(@store_name, [:set, :named_table, :public, read_concurrency: true])

    schedule_sync(sync_interval)

    {:ok, %{ets_table: ets_table, sync_interval: sync_interval}}
  end

  @impl GenServer
  def handle_call({:save, %HttpTool{} = config}, _from, state) do
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
      Logger.warning(
        "HttpToolStore: no root_path for project #{config.project_id}, ETS-only save"
      )

      :ets.insert(state.ets_table, {key, config})
      {:reply, {:ok, config}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete, user_id, project_id, tool_id}, _from, state) do
    key = {user_id, project_id, tool_id}
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

        Logger.info("HttpToolStore: hydrated #{count} HTTP tool configs for #{root_path}")
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
    all_projects = DetsManager.registered_projects()
    root_to_keys = build_root_to_keys(all_projects)

    all_projects
    |> Enum.map(fn {_, root_path} -> root_path end)
    |> Enum.uniq()
    |> Enum.each(fn root_path ->
      sync_project(ets_table, root_path, root_to_keys[root_path] || MapSet.new())
    end)
  end

  defp sync_project(ets_table, root_path, project_keys) do
    case DetsManager.lookup(root_path, @store_name) do
      nil -> :ok
      dets_ref -> sync_ets_to_dets(ets_table, dets_ref, project_keys)
    end
  end

  defp sync_ets_to_dets(ets_table, dets_ref, project_keys) do
    :ets.foldl(
      fn {{u, p, _} = key, value}, :ok ->
        if MapSet.member?(project_keys, {u, p}), do: :dets.insert(dets_ref, {key, value})
        :ok
      end,
      :ok,
      ets_table
    )

    :dets.sync(dets_ref)
  end

  defp build_root_to_keys(projects) do
    Enum.group_by(projects, fn {_, rp} -> rp end, fn {key, _} -> key end)
    |> Map.new(fn {rp, keys} -> {rp, MapSet.new(keys)} end)
  end

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
