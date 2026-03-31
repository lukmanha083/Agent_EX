defmodule AgentEx.Memory.OrchestratorContext do
  @moduledoc """
  Dynamic context window allocator for the orchestrator.

  Unlike specialist agents (which use the 4-tier memory system), the orchestrator
  manages its own context through 4 zones:

  1. **File zone** — `.memory/*.md` files (cross-session state)
  2. **Conversation zone** — Tier 1 history from previous messages in this session
  3. **Delegation zone** — agent results with round-based compression
  4. **Buffer** — headroom for tool results, save_note calls

  Each zone gets a dynamic token budget calculated from the model's context window.

  ## Zone allocation

  ```
  context_window (e.g. 200K)
  ├── response_reserve  10%
  ├── remaining         90%
  │   ├── file_zone          10% of remaining
  │   ├── conversation_zone  20% of remaining
  │   ├── delegation_zone    60% of remaining
  │   └── buffer             10% of remaining
  ```

  ## Round-based compression

  When the delegation zone is filling up, older rounds are compressed:
  - **Current round**: full result + memory report retained
  - **Previous rounds**: compressed to 1-paragraph summary each
  - **Compression trigger**: when delegation zone reaches 80% capacity
  """

  alias AgentEx.Memory.TokenBudget

  require Logger

  @response_reserve_pct 0.10
  @file_zone_pct 0.10
  @conversation_zone_pct 0.20
  @delegation_zone_pct 0.60
  @buffer_pct 0.10
  @compression_trigger 0.80

  @type zone_budgets :: %{
          response_reserve: pos_integer(),
          file_zone: pos_integer(),
          conversation_zone: pos_integer(),
          delegation_zone: pos_integer(),
          delegation_threshold: pos_integer(),
          buffer: pos_integer(),
          total_remaining: pos_integer()
        }

  @type round_entry :: %{
          round: pos_integer(),
          agent: String.t(),
          full_result: String.t(),
          memory_report: String.t(),
          summary: String.t() | nil
        }

  @doc """
  Calculate zone budgets from the model's context window size.
  """
  @spec calculate_zones(pos_integer() | nil) :: zone_budgets()
  def calculate_zones(nil), do: calculate_zones(TokenBudget.default_context_window())

  def calculate_zones(context_window) when is_integer(context_window) and context_window > 0 do
    response_reserve = trunc(context_window * @response_reserve_pct)
    remaining = context_window - response_reserve

    file_zone = trunc(remaining * @file_zone_pct)
    conversation_zone = trunc(remaining * @conversation_zone_pct)
    delegation_zone = trunc(remaining * @delegation_zone_pct)
    buffer = trunc(remaining * @buffer_pct)

    %{
      response_reserve: response_reserve,
      file_zone: file_zone,
      conversation_zone: conversation_zone,
      delegation_zone: delegation_zone,
      delegation_threshold: trunc(delegation_zone * @compression_trigger),
      buffer: buffer,
      total_remaining: remaining
    }
  end

  @doc """
  Compress delegation rounds when the zone is filling up.

  Takes the list of accumulated delegation messages and the zone budgets.
  Returns compressed messages where older rounds are summarized.

  Each delegation round consists of:
  - An assistant message with tool_calls (the delegation request)
  - A tool result message (the agent's response + memory report)
  - An assistant message (orchestrator's reasoning after getting the result)
  """
  @spec compress_delegation_rounds([map()], zone_budgets()) :: [map()]
  def compress_delegation_rounds(messages, budgets) do
    delegation_tokens = estimate_delegation_tokens(messages)

    if delegation_tokens < budgets.delegation_threshold do
      messages
    else
      do_compress_rounds(messages)
    end
  end

  @doc """
  Build a round summary from a delegation result.
  Used to compress old rounds into compact summaries.
  """
  @spec summarize_round(String.t(), String.t(), pos_integer()) :: String.t()
  def summarize_round(agent_name, result, round_num) do
    preview = String.slice(result, 0, 500)

    preview =
      if String.length(result) > 500, do: preview <> "...", else: preview

    "[Round #{round_num} — #{agent_name}]: #{preview}"
  end

  @doc """
  Check if the conversation zone needs truncation.
  Returns the number of messages to keep from the end.
  """
  @spec truncate_conversation([map()], zone_budgets()) :: [map()]
  def truncate_conversation(messages, budgets) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, tokens} ->
      msg_tokens = TokenBudget.estimate_tokens(extract_result_content(msg)) + 4

      if tokens + msg_tokens <= budgets.conversation_zone do
        {:cont, {[msg | acc], tokens + msg_tokens}}
      else
        {:halt, {acc, tokens}}
      end
    end)
    |> elem(0)
  end

  @doc """
  Check if file zone content needs truncation. Returns truncated text.
  """
  @spec truncate_file_content(String.t(), zone_budgets()) :: String.t()
  def truncate_file_content(content, budgets) do
    tokens = TokenBudget.estimate_tokens(content)

    if tokens <= budgets.file_zone do
      content
    else
      max_chars = budgets.file_zone * 4
      String.slice(content, 0, max_chars) <> "\n... (truncated to fit file zone budget)"
    end
  end

  # --- Round-based compression ---

  defp do_compress_rounds(messages) do
    rounds = identify_delegation_rounds(messages)

    case rounds do
      [] ->
        messages

      _ ->
        # Keep the last round in full, compress all previous
        {old_rounds, [current_round]} = Enum.split(rounds, -1)

        compressed =
          Enum.flat_map(old_rounds, fn {round_num, agent_name, _msgs, result_preview} ->
            summary = summarize_round(agent_name, result_preview, round_num)

            [
              %AgentEx.Message{
                role: :system,
                content: summary
              }
            ]
          end)

        # Non-delegation messages before first round
        first_round_start = first_delegation_index(messages)
        prefix = Enum.take(messages, first_round_start)

        # Current round messages in full
        {_round_num, _agent, current_msgs, _preview} = current_round

        Logger.info(
          "OrchestratorContext: compressed #{length(old_rounds)} old delegation rounds, " <>
            "keeping current round in full"
        )

        prefix ++ compressed ++ current_msgs
    end
  end

  defp identify_delegation_rounds(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce({[], nil, 0}, fn {msg, _idx}, {rounds, current_round, round_num} ->
      cond do
        # Detect delegation tool call
        delegation_call?(msg) ->
          agent_name = extract_agent_name(msg)
          new_round = round_num + 1
          {rounds, {new_round, agent_name, [msg]}, new_round}

        # Accumulate messages in current round
        current_round != nil ->
          accumulate_round_message(msg, current_round, rounds, round_num)

        # Non-delegation message
        true ->
          {rounds, current_round, round_num}
      end
    end)
    |> then(fn {rounds, current_round, _num} ->
      # Include incomplete current round
      case current_round do
        {rn, agent, msgs} -> rounds ++ [{rn, agent, msgs, ""}]
        nil -> rounds
      end
    end)
  end

  defp accumulate_round_message(msg, {rn, agent, msgs}, rounds, round_num) do
    result_preview = extract_result_content(msg)
    updated_msgs = msgs ++ [msg]

    cond do
      tool_result_or_response?(msg) and round_complete?(updated_msgs) ->
        {rounds ++ [{rn, agent, updated_msgs, result_preview}], nil, round_num}

      tool_result_or_response?(msg) ->
        {rounds, {rn, agent, updated_msgs}, round_num}

      true ->
        {rounds, {rn, agent, updated_msgs}, round_num}
    end
  end

  defp delegation_call?(%{tool_calls: calls}) when is_list(calls) and calls != [] do
    Enum.any?(calls, fn
      %{name: "delegate_to_" <> _} -> true
      _ -> false
    end)
  end

  defp delegation_call?(_), do: false

  defp extract_agent_name(%{tool_calls: calls}) when is_list(calls) do
    Enum.find_value(calls, "unknown", fn
      %{name: "delegate_to_" <> agent} -> agent
      _ -> nil
    end)
  end

  defp extract_agent_name(_), do: "unknown"

  defp extract_result_content(%{content: content}) when is_binary(content), do: content

  defp extract_result_content(%{content: results}) when is_list(results) do
    Enum.map_join(results, "\n", fn
      %{content: c} when is_binary(c) -> c
      other -> inspect(other)
    end)
  end

  defp extract_result_content(_), do: ""

  defp tool_result_or_response?(%{role: :tool}), do: true
  defp tool_result_or_response?(%{role: :assistant}), do: true
  defp tool_result_or_response?(%{content: content}) when is_list(content), do: true
  defp tool_result_or_response?(_), do: false

  defp round_complete?(msgs), do: length(msgs) >= 3

  defp first_delegation_index(messages) do
    Enum.find_index(messages, &delegation_call?/1) || length(messages)
  end

  defp estimate_delegation_tokens(messages) do
    messages
    |> Enum.filter(fn msg ->
      delegation_call?(msg) or tool_result_or_response?(msg)
    end)
    |> Enum.reduce(0, fn msg, acc ->
      content = extract_result_content(msg)
      acc + TokenBudget.estimate_tokens(content) + 4
    end)
  end
end
