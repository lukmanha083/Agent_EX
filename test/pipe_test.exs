defmodule AgentEx.PipeTest do
  use ExUnit.Case

  alias AgentEx.{Message, Pipe, Tool}
  alias AgentEx.Message.FunctionCall

  # Helper: create a stateful mock that returns pre-programmed LLM responses in order.
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

  defp uppercase_tool do
    Tool.new(
      name: "uppercase",
      description: "Convert to uppercase",
      parameters: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      function: fn %{"text" => text} -> {:ok, String.upcase(text)} end
    )
  end

  # -- Pipe.Agent struct --

  describe "Pipe.Agent" do
    test "creates with required fields" do
      agent = Pipe.Agent.new(name: "researcher", system_message: "You research things")
      assert agent.name == "researcher"
      assert agent.system_message == "You research things"
      assert agent.tools == []
      assert agent.max_iterations == 10
    end

    test "creates with all fields" do
      tool = weather_tool()

      agent =
        Pipe.Agent.new(
          name: "analyst",
          system_message: "Analyze data",
          tools: [tool],
          max_iterations: 5
        )

      assert agent.name == "analyst"
      assert length(agent.tools) == 1
      assert agent.max_iterations == 5
    end
  end

  # -- Pipe.through/4 --

  describe "through/4" do
    test "simple text response" do
      model_fn = mock_model([{:ok, Message.assistant("Analysis complete: AAPL is bullish")}])

      agent =
        Pipe.Agent.new(
          name: "analyst",
          system_message: "You are a financial analyst"
        )

      result = Pipe.through("Analyze AAPL", agent, nil, model_fn: model_fn)
      assert result == "Analysis complete: AAPL is bullish"
    end

    test "with tool calls" do
      model_fn =
        mock_model([
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{id: "c1", name: "get_weather", arguments: ~s({"city":"Tokyo"})}
           ])},
          {:ok, Message.assistant("The weather in Tokyo is Sunny, 25°C")}
        ])

      agent =
        Pipe.Agent.new(
          name: "weatherbot",
          system_message: "You check the weather",
          tools: [weather_tool()]
        )

      result = Pipe.through("What's the weather in Tokyo?", agent, nil, model_fn: model_fn)
      assert result == "The weather in Tokyo is Sunny, 25°C"
    end

    test "chains stages via pipe operator" do
      # Stage 1: researcher returns data
      researcher_fn = mock_model([{:ok, Message.assistant("AAPL is trading at $150")}])
      # Stage 2: analyst processes data
      analyst_fn = mock_model([{:ok, Message.assistant("Based on the data, AAPL is bullish")}])

      researcher =
        Pipe.Agent.new(name: "researcher", system_message: "You research stocks")

      analyst =
        Pipe.Agent.new(name: "analyst", system_message: "You analyze stock data")

      result =
        "Analyze AAPL"
        |> Pipe.through(researcher, nil, model_fn: researcher_fn)
        |> Pipe.through(analyst, nil, model_fn: analyst_fn)

      assert result == "Based on the data, AAPL is bullish"
    end
  end

  # -- Pipe.tool/2 --

  describe "tool/2" do
    test "passes string input through tool" do
      tool = uppercase_tool()
      result = Pipe.tool("hello world", tool)
      assert result == "HELLO WORLD"
    end

    test "passes map input through tool" do
      tool = weather_tool()
      result = Pipe.tool(%{"city" => "London"}, tool)
      assert result == "London: Sunny, 25°C"
    end

    test "returns error string on failure" do
      failing_tool =
        Tool.new(
          name: "fail",
          description: "Always fails",
          parameters: %{},
          function: fn _ -> {:error, "boom"} end
        )

      result = Pipe.tool("anything", failing_tool)
      assert result =~ "Error"
    end
  end

  # -- Pipe.fan_out/4 --

  describe "fan_out/4" do
    test "runs multiple agents in parallel" do
      fn1 = mock_model([{:ok, Message.assistant("Web data: AAPL earnings beat")}])
      fn2 = mock_model([{:ok, Message.assistant("Code analysis: tests pass")}])

      agent1 = Pipe.Agent.new(name: "web_researcher", system_message: "Search the web")
      agent2 = Pipe.Agent.new(name: "code_reader", system_message: "Read code")

      results =
        Pipe.fan_out("Research OTP", [agent1, agent2], nil,
          model_fn: fn messages, tools ->
            # Determine which agent this is for based on system message
            system_msg = hd(messages).content

            if system_msg =~ "web" do
              fn1.(messages, tools)
            else
              fn2.(messages, tools)
            end
          end
        )

      assert length(results) == 2
      assert Enum.any?(results, &(&1 =~ "Web data"))
      assert Enum.any?(results, &(&1 =~ "Code analysis"))
    end
  end

  # -- Pipe.merge/4 --

  describe "merge/4" do
    test "consolidates results through an agent" do
      consolidator_fn =
        mock_model([{:ok, Message.assistant("Combined report: both sources agree on bullish")}])

      consolidator =
        Pipe.Agent.new(name: "lead", system_message: "Consolidate research results")

      results = ["Source A: bullish", "Source B: strong buy"]
      result = Pipe.merge(results, consolidator, nil, model_fn: consolidator_fn)
      assert result =~ "Combined report"
    end
  end

  # -- Pipe.route/4 --

  describe "route/4" do
    test "routes to selected agent" do
      tech_fn = mock_model([{:ok, Message.assistant("Tech analysis complete")}])
      finance_fn = mock_model([{:ok, Message.assistant("Finance analysis complete")}])

      tech_agent = Pipe.Agent.new(name: "tech", system_message: "Tech analyst")
      finance_agent = Pipe.Agent.new(name: "finance", system_message: "Finance analyst")

      router = fn input ->
        if input =~ "stock", do: finance_agent, else: tech_agent
      end

      result =
        Pipe.route("Analyze AAPL stock", router, nil, model_fn: fn messages, tools ->
          system_msg = hd(messages).content
          if system_msg =~ "Finance", do: finance_fn.(messages, tools), else: tech_fn.(messages, tools)
        end)

      assert result == "Finance analysis complete"
    end
  end

  # -- Pipe.delegate_tool/4 --

  describe "delegate_tool/4" do
    test "creates a callable delegate tool" do
      sub_fn = mock_model([{:ok, Message.assistant("Research complete: found 5 papers")}])

      sub_agent =
        Pipe.Agent.new(name: "researcher", system_message: "You research topics")

      tool = Pipe.delegate_tool("researcher", sub_agent, nil, model_fn: sub_fn)

      assert tool.name == "delegate_to_researcher"
      assert tool.kind == :write
      assert tool.description =~ "researcher"

      # Execute the delegate tool
      {:ok, result} = Tool.execute(tool, %{"task" => "Find papers on OTP"})
      assert result == "Research complete: found 5 papers"
    end

    test "orchestrator uses delegate tools" do
      # Sub-agent mock: researcher
      researcher_fn = mock_model([{:ok, Message.assistant("Found: AAPL at $150")}])

      researcher =
        Pipe.Agent.new(name: "researcher", system_message: "Research stocks")

      delegate = Pipe.delegate_tool("researcher", researcher, nil, model_fn: researcher_fn)

      # Orchestrator calls delegate, then responds
      orchestrator_fn =
        mock_model([
          {:ok,
           Message.assistant_tool_calls([
             %FunctionCall{
               id: "c1",
               name: "delegate_to_researcher",
               arguments: ~s({"task":"Find AAPL price"})
             }
           ])},
          {:ok, Message.assistant("Based on research, AAPL is at $150. Recommend buy.")}
        ])

      orchestrator =
        Pipe.Agent.new(
          name: "orchestrator",
          system_message: "You coordinate research",
          tools: [delegate]
        )

      result =
        Pipe.through("Analyze AAPL", orchestrator, nil, model_fn: orchestrator_fn)

      assert result =~ "AAPL is at $150"
    end
  end

  # -- Integration: pipeline with tool + agent stages --

  describe "mixed pipeline" do
    test "tool stage followed by agent stage" do
      agent_fn = mock_model([{:ok, Message.assistant("Processed: HELLO WORLD")}])

      agent =
        Pipe.Agent.new(name: "processor", system_message: "Process the input")

      result =
        "hello world"
        |> Pipe.tool(uppercase_tool())
        |> Pipe.through(agent, nil, model_fn: agent_fn)

      assert result == "Processed: HELLO WORLD"
    end
  end
end
