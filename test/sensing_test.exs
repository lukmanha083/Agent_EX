defmodule AgentEx.SensingTest do
  use ExUnit.Case

  alias AgentEx.{Message, Sensing, Tool, ToolAgent}
  alias AgentEx.Message.{FunctionCall, FunctionResult}

  setup do
    tools = [
      Tool.new(
        name: "get_weather",
        description: "Get weather",
        parameters: %{},
        function: fn %{"city" => city} -> {:ok, "#{city}: Sunny, 25°C"} end
      ),
      Tool.new(
        name: "slow_tool",
        description: "Takes too long",
        parameters: %{},
        function: fn _ ->
          Process.sleep(5_000)
          {:ok, "done"}
        end
      ),
      Tool.new(
        name: "crash_tool",
        description: "Always crashes",
        parameters: %{},
        function: fn _ -> raise "boom" end
      )
    ]

    {:ok, agent} = ToolAgent.start_link(tools: tools)
    %{agent: agent}
  end

  describe "sense/3" do
    test "executes tool calls and returns result message + observations", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})}
      ]

      {:ok, result_message, observations} = Sensing.sense(agent, calls)

      # Result message is ready for conversation history
      assert %Message{role: :tool, content: results} = result_message
      assert [%FunctionResult{call_id: "c1", is_error: false}] = results
      assert hd(results).content =~ "Tokyo"

      # Observations match
      assert [%FunctionResult{call_id: "c1", content: "Tokyo: Sunny, 25°C"}] = observations
    end

    test "executes multiple tool calls in parallel", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "get_weather", arguments: ~s({"city": "London"})}
      ]

      {:ok, _message, observations} = Sensing.sense(agent, calls)

      assert length(observations) == 2
      assert Enum.all?(observations, &(not &1.is_error))

      contents = Enum.map(observations, & &1.content)
      assert Enum.any?(contents, &(&1 =~ "Tokyo"))
      assert Enum.any?(contents, &(&1 =~ "London"))
    end

    test "handles tool errors gracefully", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "crash_tool", arguments: "{}"}
      ]

      {:ok, _message, observations} = Sensing.sense(agent, calls)

      assert [%FunctionResult{call_id: "c1", is_error: true}] = observations
      assert hd(observations).content =~ "Error"
    end

    test "handles unknown tools as error observations", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "nonexistent", arguments: "{}"}
      ]

      {:ok, _message, observations} = Sensing.sense(agent, calls)

      assert [%FunctionResult{is_error: true}] = observations
      assert hd(observations).content =~ "unknown tool"
    end

    test "handles timeout with kill", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "slow_tool", arguments: "{}"}
      ]

      # Short timeout to trigger kill
      {:ok, _message, observations} = Sensing.sense(agent, calls, timeout: 100)

      assert [%FunctionResult{call_id: "c1", is_error: true}] = observations
      assert hd(observations).content =~ "timed out"
    end

    test "mixed success and failure", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
        %FunctionCall{id: "c2", name: "crash_tool", arguments: "{}"},
        %FunctionCall{id: "c3", name: "nonexistent", arguments: "{}"}
      ]

      {:ok, result_message, observations} = Sensing.sense(agent, calls)

      assert length(observations) == 3

      # First succeeds
      assert %FunctionResult{call_id: "c1", is_error: false} = Enum.at(observations, 0)

      # Second and third fail
      assert %FunctionResult{call_id: "c2", is_error: true} = Enum.at(observations, 1)
      assert %FunctionResult{call_id: "c3", is_error: true} = Enum.at(observations, 2)

      # Result message has all 3
      assert length(result_message.content) == 3
    end
  end

  describe "dispatch/3" do
    test "returns raw task results", %{agent: agent} do
      calls = [
        %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Berlin"})}
      ]

      results = Sensing.dispatch(agent, calls)

      assert [{:ok, %FunctionResult{call_id: "c1"}}] = results
    end
  end

  describe "process/2" do
    test "classifies successful results" do
      raw = [{:ok, %FunctionResult{call_id: "c1", name: "test", content: "ok", is_error: false}}]
      calls = [%FunctionCall{id: "c1", name: "test", arguments: "{}"}]

      observations = Sensing.process(raw, calls)

      assert [%FunctionResult{call_id: "c1", is_error: false}] = observations
    end

    test "classifies crashed results with call context" do
      raw = [{:exit, :timeout}]
      calls = [%FunctionCall{id: "c1", name: "slow_tool", arguments: "{}"}]

      observations = Sensing.process(raw, calls)

      assert [%FunctionResult{call_id: "c1", name: "slow_tool", is_error: true}] = observations
      assert hd(observations).content =~ "timed out"
    end
  end

  describe "feed_back/1" do
    test "packages observations as a tool message" do
      observations = [
        %FunctionResult{call_id: "c1", name: "test", content: "result", is_error: false}
      ]

      message = Sensing.feed_back(observations)

      assert %Message{role: :tool, content: ^observations} = message
    end
  end
end
