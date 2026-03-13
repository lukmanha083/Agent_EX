defmodule AgentEx.Memory.Message do
  @moduledoc """
  A timestamped conversation message for working memory.

  Distinct from `AgentEx.Message` which models LLM wire-format messages.
  This struct adds `timestamp` and `metadata` for memory tracking.
  """

  @type t :: %__MODULE__{
          role: String.t(),
          content: String.t(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content, timestamp: nil, metadata: %{}]

  def new(role, content, opts \\ []) do
    %__MODULE__{
      role: role,
      content: content,
      timestamp: opts[:timestamp] || DateTime.utc_now(),
      metadata: opts[:metadata] || %{}
    }
  end
end
