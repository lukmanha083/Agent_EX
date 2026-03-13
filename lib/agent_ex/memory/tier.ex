defmodule AgentEx.Memory.Tier do
  @moduledoc """
  Behaviour that all memory tiers must implement.
  All operations are scoped by `agent_id` — each agent gets its own memory view.
  """

  @callback to_context_messages(agent_id :: String.t(), identifier :: term()) ::
              [%{role: String.t(), content: String.t()}]

  @callback token_estimate(agent_id :: String.t(), identifier :: term()) :: non_neg_integer()
end
