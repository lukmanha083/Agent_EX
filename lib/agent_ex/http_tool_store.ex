defmodule AgentEx.HttpToolStore do
  @moduledoc """
  ETS + DETS persistence for HTTP tool configs.
  Same pattern as AgentStore — ETS for fast reads, DETS for disk persistence.
  Keys are `{user_id, project_id, tool_id}` for per-user, per-project isolation.
  """

  use GenServer

  alias AgentEx.HttpTool

  require Logger

  defstruct [:ets_table, :dets_table, :sync_interval]

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
    case :ets.lookup(:http_tool_configs, {user_id, project_id, tool_id}) do
      [{{^user_id, ^project_id, ^tool_id}, config}] -> {:ok, config}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "List all HTTP tool configs for a user within a project."
  def list(user_id, project_id) do
    pattern = {{user_id, project_id, :_}, :"$1"}

    :ets.match(:http_tool_configs, pattern)
    |> List.flatten()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  rescue
    ArgumentError -> []
  end

  @doc "Delete an HTTP tool config."
  def delete(user_id, project_id, tool_id) do
    GenServer.call(__MODULE__, {:delete, user_id, project_id, tool_id})
  end

  @doc "Delete all HTTP tool configs for a project. Used for cascade delete."
  def delete_by_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:delete_by_project, user_id, project_id})
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts) do
    sync_interval =
      Application.get_env(:agent_ex, :http_tool_store_sync_interval, :timer.seconds(30))

    dets_dir = Application.get_env(:agent_ex, :dets_dir, "priv/data")
    File.mkdir_p!(dets_dir)
    dets_path = Path.join(dets_dir, "http_tool_configs.dets") |> String.to_charlist()

    {:ok, dets_table} = :dets.open_file(:http_tool_configs_dets, file: dets_path, type: :set)

    ets_table =
      :ets.new(:http_tool_configs, [:set, :named_table, :public, read_concurrency: true])

    hydrate(ets_table, dets_table)
    schedule_sync(sync_interval)

    state = %__MODULE__{
      ets_table: ets_table,
      dets_table: dets_table,
      sync_interval: sync_interval
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:save, %HttpTool{} = config}, _from, state) do
    key = {config.user_id, config.project_id, config.id}

    case :dets.insert(state.dets_table, {key, config}) do
      :ok ->
        :ets.insert(state.ets_table, {key, config})
        {:reply, {:ok, config}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete, user_id, project_id, tool_id}, _from, state) do
    key = {user_id, project_id, tool_id}

    case :dets.delete(state.dets_table, key) do
      :ok ->
        :ets.delete(state.ets_table, key)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete_by_project, user_id, project_id}, _from, state) do
    keys =
      :ets.foldl(
        fn
          {{^user_id, ^project_id, _} = key, _}, acc -> [key | acc]
          _, acc -> acc
        end,
        [],
        state.ets_table
      )

    Enum.each(keys, fn key ->
      case :dets.delete(state.dets_table, key) do
        :ok ->
          :ets.delete(state.ets_table, key)

        {:error, reason} ->
          Logger.warning(
            "HttpToolStore delete_by_project: DETS delete failed for #{inspect(key)}: #{inspect(reason)}"
          )
      end
    end)

    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    sync(state.ets_table, state.dets_table)
    schedule_sync(state.sync_interval)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    sync(state.ets_table, state.dets_table)
    :dets.close(state.dets_table)
    :ok
  end

  defp hydrate(ets_table, dets_table) do
    count =
      :dets.foldl(
        fn {key, value}, acc ->
          :ets.insert(ets_table, {key, value})
          acc + 1
        end,
        0,
        dets_table
      )

    Logger.info("HttpToolStore: hydrated #{count} HTTP tool configs from DETS")
    :ok
  end

  defp sync(ets_table, dets_table) do
    :ets.foldl(
      fn {key, value}, acc ->
        case :dets.insert(dets_table, {key, value}) do
          :ok ->
            acc

          {:error, reason} ->
            Logger.warning(
              "HttpToolStore sync: DETS insert failed for #{inspect(key)}: #{inspect(reason)}"
            )

            acc
        end
      end,
      :ok,
      ets_table
    )

    :dets.sync(dets_table)
    :ok
  end

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
