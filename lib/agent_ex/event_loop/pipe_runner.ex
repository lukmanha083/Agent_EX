defmodule AgentEx.EventLoop.PipeRunner do
  @moduledoc """
  Pipe execution wrapper that broadcasts stage-level events.

  Wraps `Pipe.through/4` and `Pipe.fan_out/4` with event broadcasting
  so the UI can show pipeline progress in real-time.

  ## Events emitted

  - `:stage_start` / `:stage_complete` — per-agent pipe stage
  - `:fan_out_start` / `:fan_out_complete` — parallel execution
  - `:pipeline_complete` / `:pipeline_error` — final result
  """

  alias AgentEx.EventLoop.{Event, RunRegistry}
  alias AgentEx.{ModelClient, Pipe}

  @doc """
  Run a pipe pipeline with event broadcasting.

  Takes a pipeline function that receives the run_id-aware pipe helpers.

      PipeRunner.run("run-1", client, fn pipe ->
        "task"
        |> pipe.through.(researcher, [])
        |> pipe.through.(writer, [])
      end)
  """
  @spec run(String.t(), ModelClient.t(), (map() -> String.t()), keyword()) :: Task.t()
  def run(run_id, model_client, pipeline_fn, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    RunRegistry.register_run(run_id, metadata)

    pipe_helpers = %{
      through: &through(run_id, &1, &2, model_client, &3),
      fan_out: &fan_out(run_id, &1, &2, model_client, &3),
      merge: &merge(run_id, &1, &2, model_client, &3)
    }

    Task.Supervisor.async_nolink(AgentEx.TaskSupervisor, fn ->
      try do
        result = pipeline_fn.(pipe_helpers)
        broadcast(run_id, :pipeline_complete, %{result: result})
        RunRegistry.complete_run(run_id)
        {:ok, result}
      rescue
        e ->
          broadcast(run_id, :pipeline_error, %{reason: Exception.message(e)})
          RunRegistry.error_run(run_id)
          {:error, {:exception, Exception.message(e)}}
      end
    end)
  end

  @doc "Run a single pipe stage with event broadcasting."
  @spec through(String.t(), String.t(), Pipe.Agent.t(), ModelClient.t(), keyword()) :: String.t()
  def through(run_id, input, agent, model_client, opts \\ []) do
    broadcast(run_id, :stage_start, %{agent: agent.name})

    result = Pipe.through(input, agent, model_client, opts)

    broadcast(run_id, :stage_complete, %{
      agent: agent.name,
      output_preview: String.slice(result, 0, 200)
    })

    result
  end

  @doc "Run fan-out with event broadcasting."
  @spec fan_out(String.t(), String.t(), [Pipe.Agent.t()], ModelClient.t(), keyword()) ::
          [String.t()]
  def fan_out(run_id, input, agents, model_client, opts \\ []) do
    agent_names = Enum.map(agents, & &1.name)
    broadcast(run_id, :fan_out_start, %{agents: agent_names})

    results = Pipe.fan_out(input, agents, model_client, opts)

    broadcast(run_id, :fan_out_complete, %{
      agents: agent_names,
      result_count: length(results)
    })

    results
  end

  @doc "Run merge with event broadcasting."
  @spec merge(String.t(), [String.t()], Pipe.Agent.t(), ModelClient.t(), keyword()) :: String.t()
  def merge(run_id, results, consolidator, model_client, opts \\ []) do
    broadcast(run_id, :stage_start, %{agent: consolidator.name, type: :merge})

    result = Pipe.merge(results, consolidator, model_client, opts)

    broadcast(run_id, :stage_complete, %{
      agent: consolidator.name,
      type: :merge,
      output_preview: String.slice(result, 0, 200)
    })

    result
  end

  # -- Private --

  defp broadcast(run_id, type, data) do
    event = Event.new(type, run_id, data)
    RunRegistry.add_event(run_id, event)
    Phoenix.PubSub.broadcast(AgentEx.PubSub, "run:#{run_id}", event)
  end
end
