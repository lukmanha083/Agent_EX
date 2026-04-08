defmodule AgentEx.Specialist.Worker do
  @moduledoc """
  Per-task GenServer process. Spawned by the Pool for each dispatched task.

  Executes the specialist's ToolCallerLoop, reports the result back to
  the Orchestrator, then terminates.
  """

  use GenServer, restart: :temporary

  alias AgentEx.{Orchestrator, Specialist}

  require Logger

  defstruct [:specialist, :task, :report_to, :opts]

  def start_link({specialist, task, report_to, opts}) do
    GenServer.start_link(__MODULE__, {specialist, task, report_to, opts})
  end

  @impl true
  def init({specialist, task, report_to, opts}) do
    state = %__MODULE__{
      specialist: specialist,
      task: task,
      report_to: report_to,
      opts: opts
    }

    # Execute asynchronously so init returns immediately
    send(self(), :execute)
    {:ok, state}
  end

  @impl true
  def handle_info(:execute, state) do
    %{specialist: specialist, task: task, report_to: report_to, opts: opts} = state
    model_fn = Keyword.get(opts, :model_fn)

    Logger.info("Specialist.Worker [#{specialist.name}]: executing task #{task.id}")

    case safe_execute(specialist, task, model_fn) do
      {:ok, result_text, usage} ->
        Logger.info("Specialist.Worker [#{specialist.name}]: task #{task.id} done")
        Orchestrator.report_result(report_to, task.id, result_text, usage)

      {:error, reason} ->
        Logger.error(
          "Specialist.Worker [#{specialist.name}]: task #{task.id} failed: #{inspect(reason)}"
        )

        Orchestrator.report_result(report_to, task.id, "Error: #{inspect(reason)}", 0)
    end

    {:stop, :normal, state}
  end

  defp safe_execute(specialist, task, model_fn) do
    Specialist.execute(specialist, task, model_fn: model_fn)
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end
end
