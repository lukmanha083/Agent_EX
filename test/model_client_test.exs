defmodule AgentEx.ModelClientTest do
  use ExUnit.Case, async: true

  alias AgentEx.Message
  alias AgentEx.Message.{FunctionCall, FunctionResult}
  alias AgentEx.{ModelClient, Tool}

  describe "constructors" do
    test "openai/2 sets provider and default base_url" do
      client = ModelClient.openai("gpt-4o")
      assert client.model == "gpt-4o"
      assert client.provider == :openai
      assert client.base_url == "https://api.openai.com/v1"
    end

    test "openrouter/2 sets provider and default base_url" do
      client = ModelClient.openrouter("moonshotai/kimi-k2.5")
      assert client.model == "kimi-k2.5"
      assert client.provider == :openrouter
      assert client.base_url == "https://openrouter.ai/api/v1"
    end

    test "anthropic/2 sets provider and default base_url" do
      client = ModelClient.anthropic("claude-sonnet-4-6")
      assert client.model == "claude-sonnet-4-6"
      assert client.provider == :anthropic
      assert client.base_url == "https://api.anthropic.com"
    end

    test "new/1 defaults to openai provider" do
      client = ModelClient.new(model: "gpt-4o")
      assert client.provider == :openai
      assert client.base_url == "https://api.openai.com/v1"
    end

    test "custom base_url overrides provider default" do
      client = ModelClient.openrouter("kimi-k2.5", base_url: "http://localhost:8080")
      assert client.base_url == "http://localhost:8080"
      assert client.provider == :openrouter
    end

    test "explicit api_key is stored" do
      client = ModelClient.openai("gpt-4o", api_key: "sk-test")
      assert client.api_key == "sk-test"
    end
  end

  describe "parse_response/2 — OpenAI format" do
    test "parses text response" do
      body = %{
        "choices" => [
          %{"message" => %{"content" => "Hello world", "role" => "assistant"}}
        ]
      }

      assert {:ok, %Message{role: :assistant, content: "Hello world"}} =
               ModelClient.parse_response(body, :openai)
    end

    test "parses tool call response" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => ~s({"city": "Tokyo"})
                  }
                }
              ]
            }
          }
        ]
      }

      assert {:ok, %Message{tool_calls: [call]}} =
               ModelClient.parse_response(body, :openai)

      assert %FunctionCall{id: "call_1", name: "get_weather"} = call
      assert call.arguments == ~s({"city": "Tokyo"})
    end

    test "parses nil content as empty string" do
      body = %{"choices" => [%{"message" => %{"content" => nil}}]}

      assert {:ok, %Message{content: ""}} =
               ModelClient.parse_response(body, :openai)
    end

    test "openrouter uses same format as openai" do
      body = %{
        "choices" => [
          %{"message" => %{"content" => "Kimi says hi"}}
        ]
      }

      assert {:ok, %Message{content: "Kimi says hi"}} =
               ModelClient.parse_response(body, :openrouter)
    end
  end

  describe "parse_response/2 — Anthropic format" do
    test "parses text response" do
      body = %{
        "id" => "msg_1",
        "content" => [%{"type" => "text", "text" => "Hello from Claude"}],
        "stop_reason" => "end_turn"
      }

      assert {:ok, %Message{role: :assistant, content: "Hello from Claude"}} =
               ModelClient.parse_response(body, :anthropic)
    end

    test "parses tool use response" do
      body = %{
        "id" => "msg_1",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "get_weather",
            "input" => %{"city" => "Tokyo"}
          }
        ],
        "stop_reason" => "tool_use"
      }

      assert {:ok, %Message{tool_calls: [call]}} =
               ModelClient.parse_response(body, :anthropic)

      assert %FunctionCall{id: "toolu_1", name: "get_weather"} = call
      assert Jason.decode!(call.arguments) == %{"city" => "Tokyo"}
    end

    test "parses mixed text and tool_use blocks" do
      body = %{
        "content" => [
          %{"type" => "text", "text" => "Let me check..."},
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "search",
            "input" => %{"q" => "elixir"}
          }
        ]
      }

      assert {:ok, %Message{tool_calls: [%FunctionCall{name: "search"}]}} =
               ModelClient.parse_response(body, :anthropic)
    end
  end

  describe "Message.encode_for_anthropic/1" do
    test "extracts system messages to separate text" do
      messages = [
        Message.system("You are helpful"),
        Message.user("Hello")
      ]

      {system_text, encoded} = Message.encode_for_anthropic(messages)
      assert system_text == "You are helpful"
      assert length(encoded) == 1
      assert hd(encoded)["role"] == "user"
    end

    test "combines multiple system messages" do
      messages = [
        Message.system("Be helpful"),
        Message.system("Be concise"),
        Message.user("Hi")
      ]

      {system_text, _encoded} = Message.encode_for_anthropic(messages)
      assert system_text == "Be helpful\n\nBe concise"
    end

    test "returns nil system_text when no system messages" do
      messages = [Message.user("Hi")]
      {system_text, _} = Message.encode_for_anthropic(messages)
      assert system_text == nil
    end

    test "encodes assistant tool calls as tool_use content blocks" do
      calls = [%FunctionCall{id: "t1", name: "search", arguments: ~s({"q": "test"})}]
      messages = [Message.assistant_tool_calls(calls)]

      {_sys, [encoded]} = Message.encode_for_anthropic(messages)
      assert encoded["role"] == "assistant"
      assert [%{"type" => "tool_use", "id" => "t1", "name" => "search"}] = encoded["content"]
    end

    test "encodes tool results as user message with tool_result blocks" do
      results = [
        %FunctionResult{call_id: "t1", name: "search", content: "found it"},
        %FunctionResult{call_id: "t2", name: "fail", content: "oops", is_error: true}
      ]

      messages = [Message.tool_results(results)]

      {_sys, [encoded]} = Message.encode_for_anthropic(messages)
      assert encoded["role"] == "user"
      assert length(encoded["content"]) == 2

      [ok_block, err_block] = encoded["content"]
      assert ok_block["type"] == "tool_result"
      assert ok_block["tool_use_id"] == "t1"
      refute Map.has_key?(ok_block, "is_error")

      assert err_block["is_error"] == true
    end
  end

  describe "Tool.to_schema/2 — provider-specific encoding" do
    test "builtin tool for openrouter" do
      tool = Tool.builtin("web_search")
      schema = Tool.to_schema(tool, :openrouter)

      assert schema == %{
               "type" => "builtin_function",
               "function" => %{"name" => "web_search"}
             }
    end

    test "builtin tool for anthropic with explicit type" do
      tool = Tool.builtin("web_search", type: "web_search_20260209")
      schema = Tool.to_schema(tool, :anthropic)

      assert schema == %{
               "type" => "web_search_20260209",
               "name" => "web_search"
             }
    end

    test "builtin tool for anthropic defaults type to name" do
      tool = Tool.builtin("code_execution")
      schema = Tool.to_schema(tool, :anthropic)
      assert schema["type"] == "code_execution"
    end

    test "builtin tool for openai" do
      tool = Tool.builtin("web_search_preview")
      schema = Tool.to_schema(tool, :openai)
      assert schema == %{"type" => "web_search_preview"}
    end

    test "regular tool for anthropic uses input_schema" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Get weather",
          parameters: %{"type" => "object"},
          function: fn _ -> {:ok, "ok"} end
        )

      schema = Tool.to_schema(tool, :anthropic)
      assert schema["name"] == "get_weather"
      assert schema["input_schema"] == %{"type" => "object"}
      refute Map.has_key?(schema, "type")
    end

    test "regular tool for openai uses function wrapper" do
      tool =
        Tool.new(
          name: "calc",
          description: "Calculate",
          parameters: %{"type" => "object"},
          function: fn _ -> {:ok, "1"} end
        )

      schema = Tool.to_schema(tool, :openai)
      assert schema["type"] == "function"
      assert schema["function"]["name"] == "calc"
    end

    test "to_schema/1 still works for backward compatibility" do
      tool =
        Tool.new(
          name: "test",
          description: "Test",
          parameters: %{},
          function: fn _ -> {:ok, "ok"} end
        )

      schema = Tool.to_schema(tool)
      assert schema["type"] == "function"
      assert schema["function"]["name"] == "test"
    end
  end

  describe "Tool.builtin/2" do
    test "creates a builtin tool" do
      tool = Tool.builtin("web_search")
      assert tool.kind == :builtin
      assert tool.name == "web_search"
      assert tool.function == nil
      assert Tool.builtin?(tool)
      refute Tool.read?(tool)
      refute Tool.write?(tool)
    end

    test "builtin tool cannot be executed locally" do
      tool = Tool.builtin("web_search")
      assert {:error, _} = Tool.execute(tool, %{})
    end
  end
end
