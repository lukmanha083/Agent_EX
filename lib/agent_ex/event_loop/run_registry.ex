defmodule AgentEx.EventLoop.RunRegistry do
  @moduledoc """
  ETS-based registry for tracking active runs and replaying events.

  Stores run metadata and event history so LiveView can replay events
  on reconnection without losing state.
  """

  use GenServer

  alias AgentEx.EventLoop.Event

  @table __MODULE__
  @events_table Module.concat(__MODULE__, Events)

  @type run_status :: :running | :completed | :cancelled | :error

  @type run_info :: %{
          run_id: String.t(),
          status: run_status(),
          started_at: integer(),
          completed_at: integer() | nil,
          metadata: map()
        }

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Register a new run."
  @spec register_run(String.t(), map()) :: :ok
  def register_run(run_id, metadata \\ %{}) do
    info = %{
      run_id: run_id,
      status: :running,
      started_at: System.monotonic_time(:millisecond),
      completed_at: nil,
      metadata: metadata
    }

    :ets.insert(@table, {run_id, info})
    :ets.insert(@events_table, {run_id, []})
    :ok
  end

  @doc "Add an event to a run's history."
  @spec add_event(String.t(), Event.t()) :: :ok
  def add_event(run_id, %Event{} = event) do
    case :ets.lookup(@events_table, run_id) do
      [{^run_id, events}] ->
        :ets.insert(@events_table, {run_id, events ++ [event]})

      [] ->
        :ets.insert(@events_table, {run_id, [event]})
    end

    :ok
  end

  @doc "Get all events for a run (for replay on reconnection)."
  @spec get_events(String.t()) :: [Event.t()]
  def get_events(run_id) do
    case :ets.lookup(@events_table, run_id) do
      [{^run_id, events}] -> events
      [] -> []
    end
  end

  @doc "Get run info."
  @spec get_run(String.t()) :: {:ok, run_info()} | :not_found
  def get_run(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, info}] -> {:ok, info}
      [] -> :not_found
    end
  end

  @doc "Mark a run as completed."
  @spec complete_run(String.t()) :: :ok
  def complete_run(run_id) do
    update_status(run_id, :completed)
  end

  @doc "Mark a run as cancelled."
  @spec cancel_run(String.t()) :: :ok
  def cancel_run(run_id) do
    update_status(run_id, :cancelled)
  end

  @doc "Mark a run as errored."
  @spec error_run(String.t()) :: :ok
  def error_run(run_id) do
    update_status(run_id, :error)
  end

  @doc "List all active (running) runs."
  @spec list_active() :: [run_info()]
  def list_active do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, info} -> info end)
    |> Enum.filter(&(&1.status == :running))
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.new(@events_table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  # -- Private --

  defp update_status(run_id, status) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, info}] ->
        updated = %{info | status: status, completed_at: System.monotonic_time(:millisecond)}
        :ets.insert(@table, {run_id, updated})

      [] ->
        :ok
    end

    :ok
  end
end
