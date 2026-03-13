defmodule AgentEx.Memory.Entry do
  @moduledoc """
  A persistent memory entry (Tier 2).
  Stored in ETS/DETS with a unique key.
  """

  @type t :: %__MODULE__{
          key: String.t(),
          value: term(),
          type: String.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:key, :value, :type]
  defstruct [:key, :value, :type, :created_at, :updated_at, metadata: %{}]

  def new(key, value, type, opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      key: key,
      value: value,
      type: type,
      created_at: opts[:created_at] || now,
      updated_at: opts[:updated_at] || now,
      metadata: opts[:metadata] || %{}
    }
  end
end
