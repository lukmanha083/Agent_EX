defmodule AgentEx.HandoffTest do
  use ExUnit.Case

  alias AgentEx.{Handoff, Tool}
  alias AgentEx.Handoff.HandoffMessage
  alias AgentEx.Message.FunctionCall

  # -- HandoffMessage struct --

  describe "HandoffMessage" do
    test "creates with required target" do
      msg = %HandoffMessage{target: "analyst"}
      assert msg.target == "analyst"
      assert msg.context == []
      assert msg.content == nil
      assert msg.source == nil
    end

    test "creates with all fields" do
      msg = %HandoffMessage{
        target: "analyst",
        content: "Please analyze this data",
        source: "planner",
        context: []
      }

      assert msg.target == "analyst"
      assert msg.content == "Please analyze this data"
      assert msg.source == "planner"
    end
  end

  # -- Transfer tool generation --

  describe "transfer_tool/1" do
    test "generates a tool with correct name" do
      tool = Handoff.transfer_tool("analyst")
      assert tool.name == "transfer_to_analyst"
    end

    test "generated tool is :write kind" do
      tool = Handoff.transfer_tool("analyst")
      assert tool.kind == :write
      assert Tool.write?(tool)
    end

    test "generated tool has description mentioning target" do
      tool = Handoff.transfer_tool("financial_analyst")
      assert tool.description =~ "financial_analyst"
    end

    test "generated tool has valid parameters schema" do
      tool = Handoff.transfer_tool("writer")
      assert tool.parameters["type"] == "object"
      assert Map.has_key?(tool.parameters["properties"], "reason")
    end

    test "generated tool function returns transfer message" do
      tool = Handoff.transfer_tool("analyst")
      assert {:ok, result} = Tool.execute(tool, %{"reason" => "needs data analysis"})
      assert result =~ "Transferred to analyst"
      assert result =~ "needs data analysis"
    end

    test "generated tool function works without reason" do
      tool = Handoff.transfer_tool("analyst")
      assert {:ok, result} = Tool.execute(tool, %{})
      assert result =~ "Transferred to analyst"
    end
  end

  describe "transfer_tools/1" do
    test "generates tools for multiple targets" do
      tools = Handoff.transfer_tools(["analyst", "writer", "reviewer"])
      assert length(tools) == 3
      names = Enum.map(tools, & &1.name)
      assert "transfer_to_analyst" in names
      assert "transfer_to_writer" in names
      assert "transfer_to_reviewer" in names
    end

    test "returns empty list for empty input" do
      assert [] == Handoff.transfer_tools([])
    end
  end

  # -- Handoff detection --

  describe "transfer?/1" do
    test "returns true for transfer calls" do
      call = %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
      assert Handoff.transfer?(call)
    end

    test "returns false for regular calls" do
      call = %FunctionCall{id: "c1", name: "get_weather", arguments: "{}"}
      refute Handoff.transfer?(call)
    end

    test "returns false for similar but non-transfer names" do
      call = %FunctionCall{id: "c1", name: "transfer_money", arguments: "{}"}
      refute Handoff.transfer?(call)
    end
  end

  describe "target/1" do
    test "extracts target name from transfer call" do
      call = %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
      assert "analyst" == Handoff.target(call)
    end

    test "handles underscore-separated names" do
      call = %FunctionCall{id: "c1", name: "transfer_to_financial_analyst", arguments: "{}"}
      assert "financial_analyst" == Handoff.target(call)
    end

    test "returns nil for non-transfer calls" do
      call = %FunctionCall{id: "c1", name: "get_weather", arguments: "{}"}
      assert nil == Handoff.target(call)
    end
  end

  describe "detect/1" do
    test "finds handoff in tool calls" do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "transfer_to_analyst", arguments: "{}"}
      ]

      assert {:handoff, "analyst", %FunctionCall{id: "c2"}} = Handoff.detect(calls)
    end

    test "returns :none when no handoff present" do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "calculator", arguments: ~s({"expr": "1+1"})}
      ]

      assert :none == Handoff.detect(calls)
    end

    test "returns :none for empty list" do
      assert :none == Handoff.detect([])
    end

    test "returns first handoff if multiple present" do
      calls = [
        %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"},
        %FunctionCall{id: "c2", name: "transfer_to_writer", arguments: "{}"}
      ]

      assert {:handoff, "analyst", %FunctionCall{id: "c1"}} = Handoff.detect(calls)
    end
  end

  # -- Transfer tools integrate with Tool module --

  describe "integration with Tool" do
    test "transfer tools convert to OpenAI schema" do
      tool = Handoff.transfer_tool("analyst")
      schema = Tool.to_schema(tool)

      assert schema["type"] == "function"
      assert schema["function"]["name"] == "transfer_to_analyst"
      assert schema["function"]["description"] =~ "analyst"
      assert is_map(schema["function"]["parameters"])
    end

    test "transfer tools work with Tool.write?/read?" do
      tool = Handoff.transfer_tool("analyst")
      assert Tool.write?(tool)
      refute Tool.read?(tool)
    end
  end
end
