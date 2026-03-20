defmodule AgentEx.EventLoop do
  @moduledoc """
  Async wrapper around ToolCallerLoop that broadcasts events via PubSub.

  Bridges the synchronous ToolCallerLoop with LiveView by:
  1. Running the loop in a supervised Task
  2. Wrapping ModelClient.create with think event broadcasting
  3. Adding BroadcastHandler to the intervention pipeline
  4. Storing events in RunRegistry for replay on reconnection

  ## Usage

      {:ok, run_id} = EventLoop.run("run-1", tool_agent, client, messages, tools)
      EventLoop.subscribe("run-1")
      # Receive events as messages: %Event{type: :think_start, ...}
  """

  alias AgentEx.EventLoop.{BroadcastHandler, Event, RunRegistry}
  alias AgentEx.{ModelClient, ToolCallerLoop}

  require Logger

  @doc """
  Start an async agent run with event broadcasting.

  Returns `{:ok, run_id}`. Subscribe to events with `subscribe/1`.

  ## Options
  All `ToolCallerLoop` options plus:
  - `:metadata` — extra info stored in RunRegistry
  """
  @spec run(
          String.t(),
          GenServer.server(),
          ModelClient.t(),
          [AgentEx.Message.t()],
          [AgentEx.Tool.t()],
          keyword()
        ) :: {:ok, String.t()}
  def run(run_id, tool_agent, model_client, messages, tools, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    existing_intervention = Keyword.get(opts, :intervention, [])

    RunRegistry.register_run(run_id, metadata)

    broadcast(run_id, :stage_start, %{stage: "main"})

    # Wrap model function with think event broadcasting
    # Preserves any caller-supplied :model_fn (e.g. test stubs)
    caller_model_fn = Keyword.get(opts, :model_fn)

    model_fn = fn msgs, tls ->
      broadcast(run_id, :think_start, %{message_count: length(msgs)})

      result =
        if caller_model_fn do
          caller_model_fn.(msgs, tls)
        else
          ModelClient.create(model_client, msgs, tools: tls)
        end

      case result do
        {:ok, response} ->
          broadcast(run_id, :think_complete, %{
            has_tool_calls: is_list(response.tool_calls) and response.tool_calls != [],
            content_preview: preview(response.content)
          })

        {:error, reason} ->
          broadcast(run_id, :think_complete, %{error: inspect(reason)})
      end

      result
    end

    # Add broadcast handler to intervention pipeline
    intervention = existing_intervention ++ [BroadcastHandler.new(run_id)]

    loop_opts =
      opts
      |> Keyword.drop([:metadata])
      |> Keyword.put(:model_fn, model_fn)
      |> Keyword.put(:intervention, intervention)

    # Store a placeholder so cancel/1 knows the run is starting
    RunRegistry.mark_starting(run_id)

    task =
      Task.Supervisor.async_nolink(AgentEx.TaskSupervisor, fn ->
        result = ToolCallerLoop.run(tool_agent, model_client, messages, tools, loop_opts)

        case result do
          {:ok, generated} ->
            broadcast(run_id, :pipeline_complete, %{
              message_count: length(generated),
              final_content: final_content(generated)
            })

            RunRegistry.complete_run(run_id)
            result

          {:error, reason} ->
            broadcast(run_id, :pipeline_error, %{reason: inspect(reason)})
            RunRegistry.error_run(run_id)
            result
        end
      end)

    RunRegistry.set_task(run_id, task)

    {:ok, run_id}
  end

  @doc "Subscribe to events for a run."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(AgentEx.PubSub, "run:#{run_id}")
  end

  @doc "Cancel a running task."
  @spec cancel(String.t()) :: :ok
  def cancel(run_id) do
    case terminate_task(run_id, _retries = 3) do
      :terminated ->
        broadcast(run_id, :pipeline_error, %{reason: "cancelled"})
        RunRegistry.cancel_run(run_id)

      :not_found ->
        Logger.warning("EventLoop: cancel called for unknown run #{run_id}")
    end

    :ok
  end

  defp terminate_task(run_id, retries) do
    case RunRegistry.get_task(run_id) do
      {:ok, %Task{} = task} ->
        case Task.Supervisor.terminate_child(AgentEx.TaskSupervisor, task.pid) do
          :ok -> :terminated
          {:error, :not_found} -> :not_found
        end

      :starting when retries > 0 ->
        Process.sleep(5)
        terminate_task(run_id, retries - 1)

      _ ->
        :not_found
    end
  end

  @doc "Replay all events for a run (used on LiveView reconnection)."
  @spec replay(String.t()) :: [Event.t()]
  def replay(run_id) do
    RunRegistry.get_events(run_id)
  end

  # -- Private --

  defp broadcast(run_id, type, data) do
    event = Event.new(type, run_id, data)
    RunRegistry.add_event(run_id, event)
    Phoenix.PubSub.broadcast(AgentEx.PubSub, "run:#{run_id}", event)
  end

  defp preview(nil), do: nil
  defp preview(content) when is_binary(content), do: String.slice(content, 0, 200)
  defp preview(_), do: nil

  defp final_content(generated) do
    case List.last(generated) do
      %{content: content} when is_binary(content) -> content
      _ -> nil
    end
  end
end
