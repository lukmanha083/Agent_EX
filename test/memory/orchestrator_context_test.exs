defmodule AgentEx.Memory.OrchestratorContextTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.OrchestratorContext

  describe "calculate_zones/1" do
    test "returns zones for standard context window" do
      zones = OrchestratorContext.calculate_zones(200_000)

      assert zones.response_reserve > 0
      assert zones.file_zone > 0
      assert zones.conversation_zone > 0
      assert zones.delegation_zone > 0
      assert zones.delegation_threshold > 0
      assert zones.buffer > 0
    end

    test "delegation zone is the largest zone" do
      zones = OrchestratorContext.calculate_zones(128_000)

      assert zones.delegation_zone > zones.file_zone
      assert zones.delegation_zone > zones.conversation_zone
      assert zones.delegation_zone > zones.buffer
    end

    test "zones scale with context window" do
      small = OrchestratorContext.calculate_zones(8_000)
      large = OrchestratorContext.calculate_zones(200_000)

      assert large.delegation_zone > small.delegation_zone
      assert large.conversation_zone > small.conversation_zone
      assert large.file_zone > small.file_zone
    end

    test "nil uses default" do
      default = OrchestratorContext.calculate_zones(nil)
      assert default.delegation_zone > 0
    end

    test "delegation threshold is 80% of delegation zone" do
      zones = OrchestratorContext.calculate_zones(100_000)
      expected = trunc(zones.delegation_zone * 0.80)
      assert abs(zones.delegation_threshold - expected) <= 1
    end

    test "total zones don't exceed context window" do
      context_window = 128_000
      zones = OrchestratorContext.calculate_zones(context_window)

      total =
        zones.response_reserve + zones.file_zone + zones.conversation_zone +
          zones.delegation_zone + zones.buffer

      assert total <= context_window
    end
  end

  describe "summarize_round/3" do
    test "creates compact summary" do
      summary = OrchestratorContext.summarize_round("researcher", "Found AAPL data...", 1)
      assert summary =~ "[Round 1 — researcher]"
      assert summary =~ "Found AAPL"
    end

    test "truncates long results" do
      long_result = String.duplicate("a", 1000)
      summary = OrchestratorContext.summarize_round("coder", long_result, 3)
      assert summary =~ "[Round 3 — coder]"
      assert summary =~ "..."
      assert String.length(summary) < 600
    end
  end

  describe "truncate_conversation/2" do
    test "keeps messages within budget" do
      zones = OrchestratorContext.calculate_zones(8_000)

      messages =
        for i <- 1..100 do
          %{role: "user", content: "Message #{i}: " <> String.duplicate("x", 200)}
        end

      truncated = OrchestratorContext.truncate_conversation(messages, zones)
      assert length(truncated) < length(messages)
      assert truncated != []
    end

    test "keeps most recent messages" do
      zones = OrchestratorContext.calculate_zones(8_000)

      messages =
        for i <- 1..100 do
          %{role: "user", content: "Message #{i}"}
        end

      truncated = OrchestratorContext.truncate_conversation(messages, zones)
      last = List.last(truncated)
      assert last.content == "Message 100"
    end

    test "returns all messages if within budget" do
      zones = OrchestratorContext.calculate_zones(200_000)
      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      truncated = OrchestratorContext.truncate_conversation(messages, zones)
      assert length(truncated) == 2
    end
  end

  describe "truncate_file_content/2" do
    test "returns content unchanged if within budget" do
      zones = OrchestratorContext.calculate_zones(200_000)
      content = "# Plan\n- Step 1\n- Step 2"

      assert OrchestratorContext.truncate_file_content(content, zones) == content
    end

    test "truncates content exceeding budget" do
      zones = OrchestratorContext.calculate_zones(8_000)
      content = String.duplicate("x", 100_000)

      truncated = OrchestratorContext.truncate_file_content(content, zones)
      assert String.length(truncated) < String.length(content)
      assert truncated =~ "truncated"
    end
  end
end
