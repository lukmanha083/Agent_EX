defmodule AgentEx.SwarmTest do
  use ExUnit.Case

  alias AgentEx.Handoff.HandoffMessage
  alias AgentEx.Intervention.{PermissionHandler, WriteGateHandler}
  alias AgentEx.{Message, Swarm, Tool}
  alias AgentEx.Message.FunctionCall

  # Helper: create a stateful mock that returns pre-programmed LLM responses in order.
  # Uses an Elixir Agent (process) to track which response to return next.
  defp mock_model(responses) do
    {:ok, pid} = Agent.start_link(fn -> responses end)

    fn _messages, _tools ->
      Agent.get_and_update(pid, fn
        [response | rest] -> {response, rest}
        [] -> {{:error, :no_more_responses}, []}
      end)
    end
  end

  # Helper: a simple tool for testing
  defp weather_tool do
    Tool.new(
      name: "get_weather",
      description: "Get weather",
      kind: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      },
      function: fn %{"city" => city} -> {:ok, "#{city}: Sunny, 25°C"} end
    )
  end

  defp stock_tool do
    Tool.new(
      name: "lookup_stock",
      description: "Lookup stock price",
      kind: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{"symbol" => %{"type" => "string"}},
        "required" => ["symbol"]
      },
      function: fn %{"symbol" => sym} -> {:ok, "#{sym}: $150.00"} end
    )
  end

  # -- Swarm.Agent struct --

  describe "Swarm.Agent" do
    test "creates with required fields" do
      agent = Swarm.Agent.new(name: "planner", system_message: "You plan things")
      assert agent.name == "planner"
      assert agent.system_message == "You plan things"
      assert agent.tools == []
      assert agent.handoffs == []
    end

    test "creates with all fields" do
      tool = weather_tool()

      agent =
        Swarm.Agent.new(
          name: "analyst",
          system_message: "Analyze data",
          tools: [tool],
          handoffs: ["planner"]
        )

      assert agent.name == "analyst"
      assert length(agent.tools) == 1
      assert agent.handoffs == ["planner"]
    end
  end

  # -- Swarm.run with mock model --

  describe "Swarm.run/4" do
    test "single agent returns text response" do
      # LLM returns a direct text response (no tool calls)
      model_fn =
        mock_model([
          {:ok, Message.assistant("The weather is great!")}
        ])

      agents = [
        Swarm.Agent.new(name: "helper", system_message: "You are helpful")
      ]

      messages = [Message.user("How's the weather?")]

      {:ok, generated, handoff} =
        Swarm.run(agents, nil, messages, start: "helper", model_fn: model_fn)

      assert length(generated) == 1
      assert List.last(generated).content == "The weather is great!"
      assert handoff == nil
    end

    test "single agent uses tools then responds" do
      # LLM first calls a tool, then responds with text
      model_fn =
        mock_model([
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})}
           ])},
          {:ok, Message.assistant("It's sunny in Tokyo at 25°C!")}
        ])

      agents = [
        Swarm.Agent.new(
          name: "helper",
          system_message: "Use tools to help",
          tools: [weather_tool()]
        )
      ]

      messages = [Message.user("Weather in Tokyo?")]

      {:ok, generated, handoff} =
        Swarm.run(agents, nil, messages, start: "helper", model_fn: model_fn)

      # Should have: [tool_call_msg, tool_result_msg, text_response]
      assert length(generated) == 3
      assert List.last(generated).content == "It's sunny in Tokyo at 25°C!"
      assert handoff == nil
    end

    test "handoff transfers to another agent" do
      # Planner hands off to analyst, analyst responds
      model_fn =
        mock_model([
          # Planner: transfer to analyst
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
           ])},
          # Analyst: use stock tool
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c2", name: "lookup_stock", arguments: ~s({"symbol": "AAPL"})}
           ])},
          # Analyst: respond with analysis
          {:ok, Message.assistant("AAPL is trading at $150.00, looking strong.")}
        ])

      agents = [
        Swarm.Agent.new(
          name: "planner",
          system_message: "Route tasks to the right specialist",
          handoffs: ["analyst"]
        ),
        Swarm.Agent.new(
          name: "analyst",
          system_message: "Analyze financial data",
          tools: [stock_tool()],
          handoffs: ["planner"]
        )
      ]

      messages = [Message.user("Analyze AAPL stock")]

      {:ok, generated, handoff} =
        Swarm.run(agents, nil, messages, start: "planner", model_fn: model_fn)

      # Planner's handoff call + result + analyst's tool call + result + text response
      assert length(generated) == 5
      assert List.last(generated).content =~ "AAPL"
      assert List.last(generated).content =~ "$150.00"
      assert handoff == nil
    end

    test "handoff termination stops the swarm" do
      # Analyst finishes and hands off to "user" (termination target)
      model_fn =
        mock_model([
          # Planner: transfer to analyst
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
           ])},
          # Analyst: transfer to user (termination)
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{
               id: "c2",
               name: "transfer_to_user",
               arguments: ~s({"reason": "Need human approval"})
             }
           ])}
        ])

      agents = [
        Swarm.Agent.new(
          name: "planner",
          system_message: "Route tasks",
          handoffs: ["analyst"]
        ),
        Swarm.Agent.new(
          name: "analyst",
          system_message: "Analyze data",
          tools: [stock_tool()],
          handoffs: ["planner", "user"]
        )
      ]

      messages = [Message.user("Analyze AAPL")]

      {:ok, generated, handoff} =
        Swarm.run(agents, nil, messages,
          start: "planner",
          termination: {:handoff, "user"},
          model_fn: model_fn
        )

      # Should have handoff message
      assert %HandoffMessage{target: "user", source: "analyst"} = handoff
      assert handoff.content =~ "analyst"
      assert generated != []
    end

    test "multi-hop handoff chain" do
      # planner → analyst → writer → text response
      model_fn =
        mock_model([
          # Planner: transfer to analyst
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
           ])},
          # Analyst: transfer to writer
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c2", name: "transfer_to_writer", arguments: "{}"}
           ])},
          # Writer: final response
          {:ok, Message.assistant("Here's the report: AAPL looks bullish.")}
        ])

      agents = [
        Swarm.Agent.new(name: "planner", system_message: "Route", handoffs: ["analyst"]),
        Swarm.Agent.new(name: "analyst", system_message: "Analyze", handoffs: ["writer"]),
        Swarm.Agent.new(name: "writer", system_message: "Write reports", handoffs: ["planner"])
      ]

      messages = [Message.user("Write AAPL report")]

      {:ok, generated, handoff} =
        Swarm.run(agents, nil, messages, start: "planner", model_fn: model_fn)

      assert List.last(generated).content =~ "AAPL looks bullish"
      assert handoff == nil
    end

    test "handoff with tool calls executes both" do
      # Agent calls a tool AND a transfer in the same response
      model_fn =
        mock_model([
          # Helper: calls weather + transfers to analyst
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})},
             %FunctionCall{id: "c2", name: "transfer_to_analyst", arguments: "{}"}
           ])},
          # Analyst: responds
          {:ok, Message.assistant("Tokyo weather is sunny. Market conditions favorable.")}
        ])

      agents = [
        Swarm.Agent.new(
          name: "helper",
          system_message: "Help",
          tools: [weather_tool()],
          handoffs: ["analyst"]
        ),
        Swarm.Agent.new(
          name: "analyst",
          system_message: "Analyze",
          handoffs: ["helper"]
        )
      ]

      messages = [Message.user("Weather and market analysis")]

      {:ok, generated, _handoff} =
        Swarm.run(agents, nil, messages, start: "helper", model_fn: model_fn)

      # Both tool results should be in the messages (weather + transfer)
      assert List.last(generated).content =~ "Tokyo weather"
    end

    test "max_iterations prevents infinite loops" do
      # Agent keeps calling tools forever
      model_fn =
        mock_model(
          List.duplicate(
            {:ok,
             Message.assistant_tool_calls([
               %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city": "Tokyo"})}
             ])},
            30
          )
        )

      agents = [
        Swarm.Agent.new(
          name: "loop_agent",
          system_message: "Keep going",
          tools: [weather_tool()]
        )
      ]

      messages = [Message.user("Loop forever")]

      {:ok, generated, handoff} =
        Swarm.run(agents, nil, messages,
          start: "loop_agent",
          max_iterations: 3,
          model_fn: model_fn
        )

      # Should stop after 3 iterations
      assert handoff == nil
      # Each iteration: tool_call_msg + tool_result_msg = 2 messages
      assert length(generated) <= 6
    end

    test "unknown start agent returns error" do
      agents = [
        Swarm.Agent.new(name: "helper", system_message: "Help")
      ]

      model_fn = mock_model([])

      assert {:error, {:unknown_agent, "nonexistent"}} =
               Swarm.run(agents, nil, [], start: "nonexistent", model_fn: model_fn)
    end

    test "handoff to unknown agent returns error" do
      model_fn =
        mock_model([
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "transfer_to_ghost", arguments: "{}"}
           ])}
        ])

      agents = [
        Swarm.Agent.new(
          name: "helper",
          system_message: "Help",
          handoffs: ["ghost"]
        )
      ]

      messages = [Message.user("Transfer me")]

      assert {:error, {:unknown_agent, "ghost"}} =
               Swarm.run(agents, nil, messages, start: "helper", model_fn: model_fn)
    end

    test "model error propagates" do
      model_fn = mock_model([{:error, :api_down}])

      agents = [
        Swarm.Agent.new(name: "helper", system_message: "Help")
      ]

      assert {:error, :api_down} =
               Swarm.run(agents, nil, [Message.user("Hi")], start: "helper", model_fn: model_fn)
    end
  end

  # -- Intervention works within Swarm --

  describe "Swarm with intervention" do
    test "intervention gates transfer tools (they are :write kind)" do
      # PermissionHandler blocks all :write tools — including transfers
      model_fn =
        mock_model([
          # Agent tries to transfer (blocked by PermissionHandler)
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
           ])},
          # Agent gets "permission denied" back, responds with text
          {:ok, Message.assistant("I can't transfer, but here's my answer.")}
        ])

      agents = [
        Swarm.Agent.new(
          name: "helper",
          system_message: "Help",
          handoffs: ["analyst"]
        ),
        Swarm.Agent.new(name: "analyst", system_message: "Analyze")
      ]

      messages = [Message.user("Transfer me")]

      {:ok, generated, handoff} =
        Swarm.run(agents, nil, messages,
          start: "helper",
          intervention: [PermissionHandler],
          model_fn: model_fn
        )

      # Transfer was blocked → the handoff tool call still happened but was rejected
      # The Swarm still detects the handoff attempt via tool_calls (before intervention)
      # But since the transfer tool was rejected, the LLM sees the error and responds with text
      assert List.last(generated).content =~ "I can't transfer"
      assert handoff == nil
    end

    test "WriteGateHandler can selectively allow transfers" do
      gate = WriteGateHandler.new(allowed_writes: ["transfer_to_analyst"])

      model_fn =
        mock_model([
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "transfer_to_analyst", arguments: "{}"}
           ])},
          {:ok, Message.assistant("Analysis complete.")}
        ])

      agents = [
        Swarm.Agent.new(name: "helper", system_message: "Help", handoffs: ["analyst"]),
        Swarm.Agent.new(name: "analyst", system_message: "Analyze")
      ]

      messages = [Message.user("Analyze this")]

      {:ok, generated, _handoff} =
        Swarm.run(agents, nil, messages,
          start: "helper",
          intervention: [gate],
          model_fn: model_fn
        )

      assert List.last(generated).content == "Analysis complete."
    end
  end
end
