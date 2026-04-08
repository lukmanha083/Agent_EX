defmodule AgentEx.Specialist.Worker do
  @moduledoc """
  Per-task GenServer process. Spawned by the Pool for each dispatched task.

  Executes the specialist's ToolCallerLoop, reports the result back to
  the Orchestrator, then terminates.

  Emits agent tree events via PubSub for real-time UI visualization:
  - `:agent_spawn` — when the worker starts executing
  - `:agent_tool_call` — when a tool is invoked (via intervention handler)
  - `:agent_complete` — when execution finishes (success or error)
  """

  use GenServer, restart: :temporary

  alias AgentEx.EventLoop.{Event, RunRegistry}
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
    run_id = task[:run_id]

    Logger.info("Specialist.Worker [#{specialist.name}]: executing task #{task.id}")

    broadcast_agent_event(run_id, :agent_spawn, %{
      task_id: task.id,
      agent: specialist.name,
      model: specialist.model_client && specialist.model_client.model,
      parent: "orchestrator"
    })

    # Build intervention handler that broadcasts tool events
    extra_intervention = if run_id, do: [tool_broadcast_handler(run_id, task.id)], else: []

    case safe_execute(specialist, task, model_fn, extra_intervention) do
      {:ok, result_text, usage} ->
        Logger.info("Specialist.Worker [#{specialist.name}]: task #{task.id} done")

        broadcast_agent_event(run_id, :agent_complete, %{
          task_id: task.id,
          agent: specialist.name,
          status: :complete,
          result_preview: String.slice(result_text, 0, 200)
        })

        Orchestrator.report_result(report_to, task.id, result_text, usage)

      {:error, reason} ->
        Logger.error(
          "Specialist.Worker [#{specialist.name}]: task #{task.id} failed: #{inspect(reason)}"
        )

        broadcast_agent_event(run_id, :agent_complete, %{
          task_id: task.id,
          agent: specialist.name,
          status: :failed,
          error: inspect(reason)
        })

        Orchestrator.report_result(report_to, task.id, "Error: #{inspect(reason)}", 0)
    end

    {:stop, :normal, state}
  end

  defp safe_execute(specialist, task, model_fn, extra_intervention) do
    specialist =
      if extra_intervention != [] do
        existing = specialist.intervention || []
        %{specialist | intervention: existing ++ extra_intervention}
      else
        specialist
      end

    Specialist.execute(specialist, task, model_fn: model_fn)
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  # -- Agent tree event broadcasting --

  defp tool_broadcast_handler(run_id, task_id) do
    fn call, tool, _context ->
      broadcast_agent_event(run_id, :agent_tool_call, %{
        task_id: task_id,
        tool_name: call.name,
        call_id: call.id,
        arguments: call.arguments,
        tool_kind: tool && tool.kind
      })

      :approve
    end
  end

  defp broadcast_agent_event(nil, _type, _data), do: :ok

  defp broadcast_agent_event(run_id, type, data) do
    event = Event.new(type, run_id, data)
    RunRegistry.add_event(run_id, event)
    Phoenix.PubSub.broadcast(AgentEx.PubSub, "run:#{run_id}", event)
  end
end
