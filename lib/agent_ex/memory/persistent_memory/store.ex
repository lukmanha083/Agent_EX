defmodule AgentEx.Memory.PersistentMemory.Store do
  @moduledoc """
  Tier 2: Persistent memory using ETS (fast reads) backed by DETS (disk persistence).
  Keys are namespaced by `{agent_id, key}` so each agent has its own memory space.
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

  def put(agent_id, key, value, type, opts \\ []) do
    GenServer.call(__MODULE__, {:put, agent_id, key, value, type, opts})
  end

  def get(agent_id, key) do
    case :ets.lookup(:persistent_memory, {agent_id, key}) do
      [{{^agent_id, ^key}, entry}] -> {:ok, entry}
      [] -> :not_found
    end
  end

  def get_by_type(agent_id, type) do
    :ets.foldl(
      fn
        {{^agent_id, _key}, entry}, acc ->
          if entry.type == type, do: [entry | acc], else: acc

        _, acc ->
          acc
      end,
      [],
      :persistent_memory
    )
  end

  def delete(agent_id, key) do
    GenServer.call(__MODULE__, {:delete, agent_id, key})
  end

  def all(agent_id) do
    :ets.foldl(
      fn
        {{^agent_id, _key}, entry}, acc -> [entry | acc]
        _, acc -> acc
      end,
      [],
      :persistent_memory
    )
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages(agent_id, _identifier \\ nil) do
    entries = all(agent_id)

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
  def token_estimate(agent_id, _identifier \\ nil) do
    entries = all(agent_id)
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
  def handle_call({:put, agent_id, key, value, type, opts}, _from, state) do
    entry = Entry.new(key, value, type, opts)
    :ets.insert(state.ets_table, {{agent_id, key}, entry})
    :dets.insert(state.dets_table, {{agent_id, key}, entry})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:delete, agent_id, key}, _from, state) do
    :ets.delete(state.ets_table, {agent_id, key})
    :dets.delete(state.dets_table, {agent_id, key})
    {:reply, :ok, state}
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

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
