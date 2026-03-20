defmodule AgentEx.EventLoop.BroadcastHandler do
  @moduledoc """
  Intervention handler that broadcasts tool call events via PubSub.

  Always approves — purely observational. Used by EventLoop to emit
  real-time `:tool_call` events to LiveView subscribers.

  ## Usage

      handler = BroadcastHandler.new("run-123")
      ToolCallerLoop.run(agent, client, msgs, tools, intervention: [handler])
  """

  alias AgentEx.EventLoop.{Event, RunRegistry}

  @doc """
  Create a function-based intervention handler that broadcasts tool calls.

  Returns a closure capturing the run_id, compatible with the
  `AgentEx.Intervention` handler protocol.
  """
  @spec new(String.t()) :: (term(), term(), term() -> :approve)
  def new(run_id) do
    fn call, tool, _context ->
      event =
        Event.new(:tool_call, run_id, %{
          call_id: call.id,
          tool_name: call.name,
          arguments: call.arguments,
          tool_kind: tool && tool.kind
        })

      RunRegistry.add_event(run_id, event)
      Phoenix.PubSub.broadcast(AgentEx.PubSub, "run:#{run_id}", event)

      :approve
    end
  end

  @doc "Broadcast a tool result event."
  @spec broadcast_tool_result(String.t(), String.t(), String.t(), boolean()) :: :ok
  def broadcast_tool_result(run_id, call_id, content, is_error \\ false) do
    event =
      Event.new(:tool_result, run_id, %{
        call_id: call_id,
        content: content,
        is_error: is_error
      })

    RunRegistry.add_event(run_id, event)
    Phoenix.PubSub.broadcast(AgentEx.PubSub, "run:#{run_id}", event)
    :ok
  end
end
