defmodule AgentEx.Memory.Tier do
  @moduledoc """
  Behaviour that all memory tiers must implement.
  All operations are scoped by `{user_id, project_id, agent_id}` for multi-tenant isolation.
  """

  @type scope :: {user_id :: term(), project_id :: term(), agent_id :: String.t()}

  @callback to_context_messages(scope(), identifier :: term()) ::
              [%{role: String.t(), content: String.t()}]

  @callback token_estimate(scope(), identifier :: term()) :: non_neg_integer()
end
