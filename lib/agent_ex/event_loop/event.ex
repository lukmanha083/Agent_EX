defmodule AgentEx.EventLoop.Event do
  @moduledoc """
  Event types emitted during agent execution.

  Events are broadcast via PubSub and stored in RunRegistry for replay
  on LiveView reconnection.
  """

  @type event_type ::
          :think_start
          | :think_complete
          | :tool_call
          | :tool_result
          | :stage_start
          | :stage_complete
          | :fan_out_start
          | :fan_out_complete
          | :pipeline_complete
          | :pipeline_error

  @type t :: %__MODULE__{
          type: event_type(),
          run_id: String.t(),
          data: map(),
          timestamp: integer()
        }

  @enforce_keys [:type, :run_id]
  defstruct [:type, :run_id, data: %{}, timestamp: nil]

  @doc "Create a new event with automatic timestamp."
  def new(type, run_id, data \\ %{}) do
    %__MODULE__{
      type: type,
      run_id: run_id,
      data: data,
      timestamp: System.monotonic_time(:millisecond)
    }
  end
end
