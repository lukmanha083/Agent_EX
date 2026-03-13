defmodule AgentEx.Example do
  @moduledoc """
  Example usage showing how the pieces fit together.

  Demonstrates:
  - Read tools (sensing) vs write tools (acting)
  - Intervention handlers gating write access
  - The complete Sense-Think-Act loop
  """

  alias AgentEx.Intervention.WriteGateHandler
  alias AgentEx.{Message, ModelClient, Tool, ToolAgent, ToolCallerLoop}

  def run do
    # 1. Define tools with :kind (like Linux permissions)

    # Read tools — sensing (r--)
    weather_tool =
      Tool.new(
        name: "get_weather",
        description: "Get current weather for a city",
        kind: :read,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "description" => "The city name"}
          },
          "required" => ["city"]
        },
        function: fn %{"city" => city} ->
          {:ok, "#{city}: Sunny, 25°C, humidity 60%"}
        end
      )

    calculator_tool =
      Tool.new(
        name: "calculator",
        description: "Evaluate a math expression",
        kind: :read,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "expression" => %{"type" => "string", "description" => "Math expression"}
          },
          "required" => ["expression"]
        },
        function: fn %{"expression" => expr} ->
          {result, _} = Code.eval_string(expr)
          {:ok, "#{result}"}
        end
      )

    # Write tools — acting (rw-)
    send_email_tool =
      Tool.new(
        name: "send_email",
        description: "Send an email to a recipient",
        kind: :write,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "to" => %{"type" => "string"},
            "subject" => %{"type" => "string"},
            "body" => %{"type" => "string"}
          },
          "required" => ["to", "subject", "body"]
        },
        function: fn %{"to" => to, "subject" => subj} ->
          {:ok, "Email sent to #{to}: #{subj}"}
        end
      )

    delete_file_tool =
      Tool.new(
        name: "delete_file",
        description: "Delete a file from the filesystem",
        kind: :write,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"}
          },
          "required" => ["path"]
        },
        function: fn %{"path" => path} ->
          {:ok, "Deleted #{path}"}
        end
      )

    tools = [weather_tool, calculator_tool, send_email_tool, delete_file_tool]

    # 2. Start the ToolAgent
    {:ok, tool_agent} = ToolAgent.start_link(tools: tools)

    # 3. Create model client
    model_client = ModelClient.new(model: "gpt-4o")

    # 4. Build input messages
    input_messages = [
      Message.system("You are a helpful assistant. Use tools when needed."),
      Message.user("What's the weather in Tokyo? Then send an email to bob@example.com about it.")
    ]

    # 5. Set up intervention — allow send_email but block delete_file
    #    Like: chmod +w send_email; chmod -w delete_file
    write_gate = WriteGateHandler.new(allowed_writes: ["send_email"])

    # 6. Run the loop with intervention
    case ToolCallerLoop.run(tool_agent, model_client, input_messages, tools,
           intervention: [AgentEx.Intervention.LogHandler, write_gate]
         ) do
      {:ok, generated} ->
        final = List.last(generated)
        IO.puts("Final response: #{final.content}")
        {:ok, generated}

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
