defmodule AgentEx.Memory.TokenBudget do
  @moduledoc """
  Calculates dynamic token budgets from the agent's context window size.

  Instead of hardcoded budgets, all memory tier allocations are computed as
  percentages of the available context window. This ensures a 200K model
  gets generous memory injection while an 8K model stays lean.

  ## Budget zones

  ```
  context_window (e.g. 128_000)
  ├── response_reserve   10%  — room for model output
  ├── system_reserve      5%  — AgentConfig system prompt
  └── remaining          85%
      ├── memory_zone    15% of remaining
      │   ├── persistent      20% of memory
      │   ├── knowledge_graph  30% of memory
      │   ├── semantic         20% of memory
      │   └── procedural       30% of memory
      └── conversation_zone  85% of remaining
          └── compress at 80% of conversation_zone
  ```
  """

  @default_context_window 32_000

  # Zone allocation as fractions of context_window
  @response_reserve 0.10
  @system_reserve 0.05

  # Memory zone as fraction of remaining (after reserves)
  @memory_fraction 0.15
  @conversation_fraction 0.85

  # Memory tier allocation within memory zone
  @tier_ratios %{
    persistent: 0.20,
    knowledge_graph: 0.30,
    semantic: 0.20,
    procedural: 0.30
  }

  # Compress conversation when it reaches this fraction of its zone
  @compression_threshold 0.80

  @type budgets :: %{
          persistent: pos_integer(),
          knowledge_graph: pos_integer(),
          semantic: pos_integer(),
          procedural: pos_integer(),
          conversation: pos_integer(),
          total: pos_integer(),
          compression_threshold: pos_integer(),
          response_reserve: pos_integer(),
          system_reserve: pos_integer()
        }

  @doc """
  Calculate all token budgets from a context window size.

  Returns a map with per-tier budgets and the compression threshold.

  ## Examples

      iex> TokenBudget.calculate(128_000)
      %{persistent: 3264, knowledge_graph: 4896, ...}

      iex> TokenBudget.calculate(8_000)
      %{persistent: 204, knowledge_graph: 306, ...}

      iex> TokenBudget.calculate(nil)  # uses default 32K
      %{persistent: 816, ...}
  """
  @spec calculate(pos_integer() | nil) :: budgets()
  def calculate(nil), do: calculate(@default_context_window)

  def calculate(context_window) when is_integer(context_window) and context_window > 0 do
    response_reserve = trunc(context_window * @response_reserve)
    system_reserve = trunc(context_window * @system_reserve)
    remaining = context_window - response_reserve - system_reserve

    memory_zone = trunc(remaining * @memory_fraction)
    conversation_zone = trunc(remaining * @conversation_fraction)

    %{
      persistent: trunc(memory_zone * @tier_ratios.persistent),
      knowledge_graph: trunc(memory_zone * @tier_ratios.knowledge_graph),
      semantic: trunc(memory_zone * @tier_ratios.semantic),
      procedural: trunc(memory_zone * @tier_ratios.procedural),
      conversation: conversation_zone,
      total: memory_zone + conversation_zone,
      compression_threshold: trunc(conversation_zone * @compression_threshold),
      response_reserve: response_reserve,
      system_reserve: system_reserve
    }
  end

  @doc """
  Estimate token count from text using the ~4 chars/token heuristic.
  """
  @spec estimate_tokens(String.t() | list() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(text) when is_binary(text), do: div(String.length(text), 4)

  def estimate_tokens(content) when is_list(content) do
    Enum.reduce(content, 0, fn
      %{content: c}, acc when is_binary(c) -> acc + div(String.length(c), 4)
      _, acc -> acc
    end)
  end

  @doc """
  Estimate total tokens in a list of messages.
  """
  @spec estimate_messages_tokens([map()]) :: non_neg_integer()
  def estimate_messages_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content = Map.get(msg, :content) || Map.get(msg, "content")
      acc + estimate_tokens(content) + 4
    end)
  end

  @doc """
  Check if conversation tokens exceed the compression threshold.
  """
  @spec needs_compression?(non_neg_integer(), budgets()) :: boolean()
  def needs_compression?(conversation_tokens, %{compression_threshold: threshold}) do
    conversation_tokens >= threshold
  end

  @doc "Returns the default context window size."
  @spec default_context_window() :: pos_integer()
  def default_context_window, do: @default_context_window
end
