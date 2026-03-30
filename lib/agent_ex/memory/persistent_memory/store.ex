defmodule AgentEx.Memory.PersistentMemory.Store do
  @moduledoc """
  Tier 2: Persistent memory using ETS (fast reads) backed by DETS (disk persistence).
  Keys are `{user_id, project_id, agent_id, key}` for per-user, per-project, per-agent isolation.

  All public functions take `(user_id, project_id, agent_id, ...)` as the first three params
  to enforce proper multi-tenant scoping. There are no fallback fold paths.
  """

  use GenServer

  @behaviour AgentEx.Memory.Tier

  alias AgentEx.Memory.Entry
  alias AgentEx.Memory.PersistentMemory.Loader

  require Logger

  defstruct [:ets_table, :dets_table, :sync_interval]

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
    case :ets.lookup(:persistent_memory, {user_id, project_id, agent_id, key}) do
      [{_key, entry}] -> {:ok, entry}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "Return all entries matching `(user_id, project_id, agent_id)` with the given type."
  def get_by_type(user_id, project_id, agent_id, type) do
    :ets.foldl(
      fn
        {{^user_id, ^project_id, ^agent_id, _key}, entry}, acc ->
          if entry.type == type, do: [entry | acc], else: acc

        _, acc ->
          acc
      end,
      [],
      :persistent_memory
    )
  rescue
    ArgumentError -> []
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

  @doc "Return all entries for `(user_id, project_id, agent_id)`. Reads directly from ETS."
  def all(user_id, project_id, agent_id) do
    :ets.foldl(
      fn
        {{^user_id, ^project_id, ^agent_id, _key}, entry}, acc -> [entry | acc]
        _, acc -> acc
      end,
      [],
      :persistent_memory
    )
  rescue
    ArgumentError -> []
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
      Application.get_env(:agent_ex, :persistent_memory_sync_interval, :timer.seconds(30))

    dets_dir = Application.get_env(:agent_ex, :dets_dir, "priv/data")
    File.mkdir_p!(dets_dir)
    dets_path = Path.join(dets_dir, "persistent_memory.dets") |> String.to_charlist()

    {:ok, dets_table} = :dets.open_file(:persistent_memory_dets, file: dets_path, type: :set)

    ets_table =
      :ets.new(:persistent_memory, [:set, :named_table, :public, read_concurrency: true])

    Loader.hydrate(ets_table, dets_table)
    schedule_sync(sync_interval)

    state = %__MODULE__{
      ets_table: ets_table,
      dets_table: dets_table,
      sync_interval: sync_interval
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:put, user_id, project_id, agent_id, key, value, type, opts}, _from, state) do
    entry = Entry.new(key, value, type, opts)
    ets_key = {user_id, project_id, agent_id, key}

    case :dets.insert(state.dets_table, {ets_key, entry}) do
      :ok ->
        :ets.insert(state.ets_table, {ets_key, entry})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete, user_id, project_id, agent_id, key}, _from, state) do
    ets_key = {user_id, project_id, agent_id, key}

    case :dets.delete(state.dets_table, ets_key) do
      :ok ->
        :ets.delete(state.ets_table, ets_key)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete_all, user_id, project_id, agent_id}, _from, state) do
    keys =
      :ets.foldl(
        fn
          {{^user_id, ^project_id, ^agent_id, _} = k, _}, acc -> [k | acc]
          _, acc -> acc
        end,
        [],
        state.ets_table
      )

    delete_keys(state, keys)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_call({:delete_by_project, user_id, project_id}, _from, state) do
    keys =
      :ets.foldl(
        fn
          {{^user_id, ^project_id, _, _} = k, _}, acc -> [k | acc]
          _, acc -> acc
        end,
        [],
        state.ets_table
      )

    delete_keys(state, keys)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    Loader.sync(state.ets_table, state.dets_table)
    schedule_sync(state.sync_interval)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Loader.sync(state.ets_table, state.dets_table)
    :dets.close(state.dets_table)
    :ok
  end

  # --- Private helpers ---

  defp delete_keys(state, keys) do
    Enum.each(keys, fn key ->
      case :dets.delete(state.dets_table, key) do
        :ok ->
          :ets.delete(state.ets_table, key)

        {:error, reason} ->
          Logger.warning(
            "PersistentMemory: DETS delete failed for #{inspect(key)}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
