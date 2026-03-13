defmodule AgentExTest do
  use ExUnit.Case

  alias AgentEx.{Message, Tool, ToolAgent}
  alias AgentEx.Message.{FunctionCall, FunctionResult}

  describe "Tool" do
    test "executes a tool function" do
      tool =
        Tool.new(
          name: "add",
          description: "Add two numbers",
          parameters: %{},
          function: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
        )

      assert {:ok, 5} = Tool.execute(tool, %{"a" => 2, "b" => 3})
    end

    test "converts to OpenAI schema" do
      tool =
        Tool.new(
          name: "greet",
          description: "Say hello",
          parameters: %{"type" => "object"},
          function: fn _ -> {:ok, "hi"} end
        )

      schema = Tool.to_schema(tool)
      assert schema["type"] == "function"
      assert schema["function"]["name"] == "greet"
    end
  end

  describe "ToolAgent" do
    test "executes a registered tool" do
      tool =
        Tool.new(
          name: "double",
          description: "Double a number",
          parameters: %{},
          function: fn %{"n" => n} -> {:ok, n * 2} end
        )

      {:ok, agent} = ToolAgent.start_link(tools: [tool])

      call = %FunctionCall{id: "call_1", name: "double", arguments: ~s({"n": 5})}
      result = ToolAgent.execute(agent, call)

      assert %FunctionResult{call_id: "call_1", content: "10", is_error: false} = result
    end

    test "returns error for unknown tool" do
      {:ok, agent} = ToolAgent.start_link(tools: [])

      call = %FunctionCall{id: "call_2", name: "missing", arguments: "{}"}
      result = ToolAgent.execute(agent, call)

      assert %FunctionResult{is_error: true} = result
      assert result.content =~ "unknown tool"
    end
  end

  describe "Message" do
    test "creates message types" do
      assert %Message{role: :system} = Message.system("You are helpful")
      assert %Message{role: :user, source: "user"} = Message.user("Hello")
      assert %Message{role: :assistant} = Message.assistant("Hi there")
    end
  end
end
