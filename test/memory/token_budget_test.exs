defmodule AgentEx.Memory.TokenBudgetTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.TokenBudget

  describe "calculate/1" do
    test "returns budgets for standard context window" do
      budgets = TokenBudget.calculate(128_000)

      assert budgets.persistent > 0
      assert budgets.knowledge_graph > 0
      assert budgets.semantic > 0
      assert budgets.procedural > 0
      assert budgets.conversation > 0
      assert budgets.compression_threshold > 0
      assert budgets.response_reserve > 0
      assert budgets.system_reserve > 0
    end

    test "budgets scale with context window" do
      small = TokenBudget.calculate(8_000)
      large = TokenBudget.calculate(200_000)

      assert large.persistent > small.persistent
      assert large.conversation > small.conversation
      assert large.compression_threshold > small.compression_threshold
    end

    test "nil uses default context window" do
      default = TokenBudget.calculate(nil)
      explicit = TokenBudget.calculate(TokenBudget.default_context_window())

      assert default == explicit
    end

    test "memory zone is smaller than conversation zone" do
      budgets = TokenBudget.calculate(128_000)
      memory_total = budgets.persistent + budgets.knowledge_graph + budgets.semantic + budgets.procedural

      assert budgets.conversation > memory_total
    end

    test "compression threshold is 80% of conversation zone" do
      budgets = TokenBudget.calculate(100_000)

      # Allow small rounding tolerance
      expected = trunc(budgets.conversation * 0.80)
      assert abs(budgets.compression_threshold - expected) <= 1
    end

    test "total reserves don't exceed context window" do
      context_window = 32_000
      budgets = TokenBudget.calculate(context_window)
      total_used = budgets.total + budgets.response_reserve + budgets.system_reserve

      assert total_used <= context_window
    end
  end

  describe "estimate_tokens/1" do
    test "estimates based on char count" do
      assert TokenBudget.estimate_tokens("hello world") == 2
      assert TokenBudget.estimate_tokens(String.duplicate("a", 400)) == 100
    end

    test "handles nil" do
      assert TokenBudget.estimate_tokens(nil) == 0
    end
  end

  describe "estimate_messages_tokens/1" do
    test "sums token estimates across messages" do
      messages = [
        %{content: String.duplicate("a", 100)},
        %{content: String.duplicate("b", 200)}
      ]

      # 100/4 + 4 overhead + 200/4 + 4 overhead = 25 + 4 + 50 + 4 = 83
      assert TokenBudget.estimate_messages_tokens(messages) == 83
    end

    test "handles empty list" do
      assert TokenBudget.estimate_messages_tokens([]) == 0
    end
  end

  describe "needs_compression?/2" do
    test "returns true when over threshold" do
      budgets = TokenBudget.calculate(32_000)
      assert TokenBudget.needs_compression?(budgets.compression_threshold + 1, budgets)
    end

    test "returns false when under threshold" do
      budgets = TokenBudget.calculate(32_000)
      refute TokenBudget.needs_compression?(budgets.compression_threshold - 1, budgets)
    end
  end
end
