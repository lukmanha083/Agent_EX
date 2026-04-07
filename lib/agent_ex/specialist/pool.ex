defmodule AgentEx.Specialist.Pool do
  @moduledoc """
  ConsumerSupervisor that subscribes to an Orchestrator GenStage producer.

  For each task event received, spawns a Specialist.Worker process that
  executes the task and reports the result back to the Orchestrator.

  Backpressure is automatic — the Pool only requests tasks when it has
  capacity (controlled by max_demand).
  """

  use ConsumerSupervisor

  alias AgentEx.Orchestrator

  require Logger

  def start_link(opts) do
    ConsumerSupervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    orchestrator = Keyword.fetch!(opts, :orchestrator)
    specialists = Keyword.fetch!(opts, :specialists)
    max_demand = Keyword.get(opts, :max_demand, 3)
    pool_opts = Keyword.get(opts, :pool_opts, [])

    children = [
      %{
        id: AgentEx.Specialist.Worker,
        start: {AgentEx.Specialist.Worker, :start_link, []},
        restart: :temporary
      }
    ]

    consumer_opts = [
      strategy: :one_for_one,
      subscribe_to: [{orchestrator, max_demand: max_demand}]
    ]

    # Store specialists and opts in process dictionary for handle_events
    Process.put(:specialists, specialists)
    Process.put(:orchestrator, orchestrator)
    Process.put(:pool_opts, pool_opts)

    ConsumerSupervisor.init(children, consumer_opts)
  end

  @doc """
  Called by ConsumerSupervisor for each task event from the Orchestrator.

  Looks up the specialist config by name and starts a Worker process.
  """
  def handle_events(tasks, _from, state) do
    specialists = Process.get(:specialists, %{})
    orchestrator = Process.get(:orchestrator)
    pool_opts = Process.get(:pool_opts, [])

    Enum.each(tasks, fn task ->
      case Map.get(specialists, task.specialist) do
        nil ->
          Logger.warning(
            "Pool: no specialist '#{task.specialist}' found, skipping task #{task.id}"
          )

          Orchestrator.report_result(orchestrator, task.id, "Error: unknown specialist", 0)

        specialist ->
          start_worker(specialist, task, orchestrator, pool_opts)
      end
    end)

    {:noreply, [], state}
  end

  defp start_worker(specialist, task, orchestrator, pool_opts) do
    case DynamicSupervisor.start_child(
           AgentEx.Specialist.DelegationSupervisor,
           {AgentEx.Specialist.Worker, {specialist, task, orchestrator, pool_opts}}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("Pool: failed to start worker for task #{task.id}: #{inspect(reason)}")

        AgentEx.Orchestrator.report_result(
          orchestrator,
          task.id,
          "Error: worker start failed",
          0
        )
    end
  end
end
