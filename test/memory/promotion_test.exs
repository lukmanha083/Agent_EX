defmodule AgentEx.Memory.PromotionTest do
  use ExUnit.Case, async: false

  alias AgentEx.Memory.Promotion
  alias AgentEx.{ModelClient, Tool}

  describe "save_memory_tool/1" do
    test "returns a Tool struct" do
      tool = Promotion.save_memory_tool(agent_id: "test_agent")
      assert %Tool{} = tool
      assert tool.name == "save_memory"
      assert tool.kind == :write
      assert tool.parameters["required"] == ["fact"]
    end

    test "tool has required parameter schema" do
      tool = Promotion.save_memory_tool(agent_id: "test_agent")
      props = tool.parameters["properties"]
      assert Map.has_key?(props, "fact")
      assert Map.has_key?(props, "category")
      assert props["category"]["enum"] == ["preference", "decision", "insight", "outcome", "fact"]
    end
  end

  describe "close_session_with_summary/4" do
    test "returns empty string for empty session" do
      agent_id = "promo_test_#{System.unique_integer([:positive])}"
      session_id = "sess_empty"

      AgentEx.Memory.start_session(agent_id, session_id)

      # Use a dummy client — should never be called for empty sessions
      client = ModelClient.new(model: "test", api_key: "test")

      assert {:ok, ""} = Promotion.close_session_with_summary(agent_id, session_id, client)
    end
  end
end
