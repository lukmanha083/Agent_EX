defmodule AgentEx.Memory.PersistentMemory.Store do
  @moduledoc """
  Tier 2: Persistent memory using ETS (fast reads) backed by per-project DETS (disk persistence).
  Keys are `{user_id, project_id, agent_id, key}` for per-user, per-project, per-agent isolation.

  ## Upgrades
  - Secondary index ETS table for O(1) type-based lookups
  - `write_concurrency: true` for parallel writes from multiple processes
  - 5-second sync interval (down from 30s) to reduce data loss window
  - ETS `match_object` patterns instead of `foldl` for faster scans
  """

  use GenServer

  @behaviour AgentEx.Memory.Tier

  alias AgentEx.DetsManager
  alias AgentEx.Memory.Entry

  require Logger

  @store_name :persistent_memory
  @index_name :persistent_memory_idx
  @default_sync_interval :timer.seconds(5)

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a persistent memory entry scoped by `(user_id, project_id, agent_id)`.

  ## Options
  - `:metadata` — additional metadata map
  """
  def put(user_id, project_id, agent_id, key, value, type, opts \\ []) do
    GenServer.call(__MODULE__, {:put, user_id, project_id, agent_id, key, value, type, opts})
  end

  @doc "Direct ETS lookup by `(user_id, project_id, agent_id, key)`."
  def get(user_id, project_id, agent_id, key) do
    case :ets.lookup(@store_name, {user_id, project_id, agent_id, key}) do
      [{_key, entry}] -> {:ok, entry}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "Return all entries matching `(user_id, project_id, agent_id)` with the given type."
  def get_by_type(user_id, project_id, agent_id, type) do
    index_key = {user_id, project_id, agent_id, type}

    case :ets.lookup(@index_name, index_key) do
      [{^index_key, keys}] -> lookup_entries(keys)
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp lookup_entries(keys) do
    Enum.flat_map(keys, fn key ->
      case :ets.lookup(@store_name, key) do
        [{_k, entry}] -> [entry]
        [] -> []
      end
    end)
  end

  @doc "Delete a single entry by `(user_id, project_id, agent_id, key)`."
  def delete(user_id, project_id, agent_id, key) do
    GenServer.call(__MODULE__, {:delete, user_id, project_id, agent_id, key})
  end

  @doc "Delete all entries for an agent scoped by `(user_id, project_id, agent_id)`."
  def delete_all(user_id, project_id, agent_id) do
    GenServer.call(__MODULE__, {:delete_all, user_id, project_id, agent_id})
  end

  @doc "Delete all entries for a user's project (cascade delete)."
  def delete_by_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:delete_by_project, user_id, project_id})
  end

  @doc "Return all entries for `(user_id, project_id, agent_id)`. Uses ETS match_object."
  def all(user_id, project_id, agent_id) do
    pattern = {{user_id, project_id, agent_id, :_}, :_}

    :ets.match_object(@store_name, pattern)
    |> Enum.map(fn {_key, entry} -> entry end)
  rescue
    ArgumentError -> []
  end

  @doc "Hydrate a project's persistent memory from DETS into ETS."
  def hydrate_project(root_path) do
    GenServer.call(__MODULE__, {:hydrate_project, root_path})
  end

  @doc "Evict a project's data from ETS."
  def evict_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:evict_project, user_id, project_id})
  end

  # --- Tier callbacks ---

  @internal_types ["procedural_observation"]

  @impl AgentEx.Memory.Tier
  def to_context_messages({user_id, project_id, agent_id}, _identifier \\ nil) do
    entries =
      all(user_id, project_id, agent_id)
      |> Enum.reject(&(&1.type in @internal_types))

    if entries == [] do
      []
    else
      grouped = format_grouped_entries(entries)
      [%{role: "system", content: "## User Preferences & Facts\n#{grouped}"}]
    end
  end

  defp format_grouped_entries(entries) do
    entries
    |> Enum.group_by(& &1.type)
    |> Enum.map_join("\n", fn {type, items} ->
      "### #{type}\n" <> Enum.map_join(items, "\n", fn e -> "- #{e.key}: #{e.value}" end)
    end)
  end

  @impl AgentEx.Memory.Tier
  def token_estimate({user_id, project_id, agent_id}, _identifier \\ nil) do
    entries = all(user_id, project_id, agent_id)
    Enum.reduce(entries, 0, fn e, acc -> acc + div(String.length("#{e.key}: #{e.value}"), 4) end)
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts) do
    sync_interval =
      Application.get_env(:agent_ex, :persistent_memory_sync_interval, @default_sync_interval)

    ets_table =
      :ets.new(@store_name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Secondary index: {user_id, project_id, agent_id, type} → [ets_key]
    :ets.new(@index_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sync(sync_interval)

    {:ok, %{ets_table: ets_table, sync_interval: sync_interval}}
  end

  @impl GenServer
  def handle_call({:put, user_id, project_id, agent_id, key, value, type, opts}, _from, state) do
    entry = Entry.new(key, value, type, opts)
    ets_key = {user_id, project_id, agent_id, key}
    root_path = DetsManager.root_path_for(user_id, project_id)

    # Look up old entry to update index if type changed
    old_type = lookup_entry_type(ets_key)

    if root_path do
      case ensure_dets_and_insert(root_path, ets_key, entry) do
        :ok ->
          :ets.insert(state.ets_table, {ets_key, entry})
          update_index(user_id, project_id, agent_id, ets_key, type, old_type)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      Logger.warning("PersistentMemory: no root_path for project #{project_id}, ETS-only save")
      :ets.insert(state.ets_table, {ets_key, entry})
      update_index(user_id, project_id, agent_id, ets_key, type, old_type)
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call({:delete, user_id, project_id, agent_id, key}, _from, state) do
    ets_key = {user_id, project_id, agent_id, key}
    root_path = DetsManager.root_path_for(user_id, project_id)

    # Remove from index before deleting
    old_type = lookup_entry_type(ets_key)
    if old_type, do: remove_from_index(user_id, project_id, agent_id, ets_key, old_type)

    if root_path do
      case resolve_dets(root_path) do
        {:ok, dets_ref} -> :dets.delete(dets_ref, ets_key)
        _ -> :ok
      end
    end

    :ets.delete(state.ets_table, ets_key)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:delete_all, user_id, project_id, agent_id}, _from, state) do
    pattern = {{user_id, project_id, agent_id, :_}, :_}
    keys = :ets.match_object(state.ets_table, pattern) |> Enum.map(fn {k, _} -> k end)

    delete_keys(state, keys, user_id, project_id)
    clear_agent_index(user_id, project_id, agent_id)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_call({:delete_by_project, user_id, project_id}, _from, state) do
    pattern = {{user_id, project_id, :_, :_}, :_}
    keys = :ets.match_object(state.ets_table, pattern) |> Enum.map(fn {k, _} -> k end)

    delete_keys(state, keys, user_id, project_id)
    clear_project_index(user_id, project_id)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_call({:hydrate_project, root_path}, _from, state) do
    case DetsManager.open(root_path, @store_name) do
      {:ok, dets_ref} ->
        count =
          :dets.foldl(
            fn {key, value} = record, acc ->
              :ets.insert(state.ets_table, record)
              {user_id, project_id, agent_id, _k} = key
              add_to_index(user_id, project_id, agent_id, key, value.type)
              acc + 1
            end,
            0,
            dets_ref
          )

        Logger.info("PersistentMemory: hydrated #{count} entries for #{root_path}")
        {:reply, {:ok, count}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:evict_project, user_id, project_id}, _from, state) do
    pattern = {{user_id, project_id, :_, :_}, :_}
    keys = :ets.match_object(state.ets_table, pattern) |> Enum.map(fn {k, _} -> k end)

    Enum.each(keys, fn key -> :ets.delete(state.ets_table, key) end)
    clear_project_index(user_id, project_id)
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

  # --- Index management ---

  defp update_index(user_id, project_id, agent_id, ets_key, new_type, old_type) do
    if old_type && old_type != new_type do
      remove_from_index(user_id, project_id, agent_id, ets_key, old_type)
    end

    add_to_index(user_id, project_id, agent_id, ets_key, new_type)
  end

  defp add_to_index(user_id, project_id, agent_id, ets_key, type) do
    index_key = {user_id, project_id, agent_id, type}

    case :ets.lookup(@index_name, index_key) do
      [{^index_key, keys}] ->
        unless ets_key in keys do
          :ets.insert(@index_name, {index_key, [ets_key | keys]})
        end

      [] ->
        :ets.insert(@index_name, {index_key, [ets_key]})
    end
  end

  defp remove_from_index(user_id, project_id, agent_id, ets_key, type) do
    index_key = {user_id, project_id, agent_id, type}

    case :ets.lookup(@index_name, index_key) do
      [{^index_key, keys}] ->
        remaining = List.delete(keys, ets_key)

        if remaining == [] do
          :ets.delete(@index_name, index_key)
        else
          :ets.insert(@index_name, {index_key, remaining})
        end

      [] ->
        :ok
    end
  end

  defp lookup_entry_type(ets_key) do
    case :ets.lookup(@store_name, ets_key) do
      [{_k, entry}] -> entry.type
      [] -> nil
    end
  end

  defp clear_agent_index(user_id, project_id, agent_id) do
    pattern = {{user_id, project_id, agent_id, :_}, :_}

    :ets.match_object(@index_name, pattern)
    |> Enum.each(fn {k, _} -> :ets.delete(@index_name, k) end)
  end

  defp clear_project_index(user_id, project_id) do
    pattern = {{user_id, project_id, :_, :_}, :_}

    :ets.match_object(@index_name, pattern)
    |> Enum.each(fn {k, _} -> :ets.delete(@index_name, k) end)
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

  defp delete_keys(state, keys, user_id, project_id) do
    root_path = DetsManager.root_path_for(user_id, project_id)

    dets_ref =
      if root_path do
        case resolve_dets(root_path) do
          {:ok, ref} -> ref
          _ -> nil
        end
      end

    Enum.each(keys, fn key ->
      if dets_ref, do: :dets.delete(dets_ref, key)
      :ets.delete(state.ets_table, key)
    end)
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
      fn {{u, p, _, _} = key, value}, :ok ->
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
