defmodule AgentEx.SpecialistTest do
  use ExUnit.Case, async: true

  alias AgentEx.{ModelClient, Specialist}

  @moduletag :specialist

  describe "execute/3" do
    test "runs a specialist with model_fn and returns result" do
      specialist = %Specialist{
        name: "researcher",
        system_message: "You are a research specialist.",
        model_client: ModelClient.new(model: "test"),
        tools: [],
        max_iterations: 1
      }

      task = %{id: "t1", specialist: "researcher", input: "find AAPL earnings"}

      # model_fn returns a direct text response (no tool calls)
      # ToolCallerLoop expects fn(messages, tools)
      model_fn = fn _messages, _tools ->
        {:ok,
         %AgentEx.Message{
           role: :assistant,
           content: "AAPL Q4 revenue was $94.9B, up 6% YoY."
         }}
      end

      result = Specialist.execute(specialist, task, model_fn: model_fn)

      assert {:ok, text, _usage} = result
      assert text =~ "AAPL"
    end

    test "returns error when model_fn fails" do
      specialist = %Specialist{
        name: "failing",
        system_message: "You will fail.",
        model_client: ModelClient.new(model: "test"),
        tools: [],
        max_iterations: 1
      }

      task = %{id: "t2", specialist: "failing", input: "do something"}

      model_fn = fn _messages, _tools ->
        {:error, :api_error}
      end

      result = Specialist.execute(specialist, task, model_fn: model_fn)

      assert {:error, :api_error} = result
    end
  end
end
