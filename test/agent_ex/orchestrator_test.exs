defmodule AgentEx.OrchestratorTest do
  use ExUnit.Case, async: true

  alias AgentEx.{ModelClient, Orchestrator}

  @moduletag :orchestrator

  # Fake model client (not used when model_fn overrides)
  defp fake_client, do: ModelClient.new(model: "test")

  defp fake_specialists do
    %{
      "researcher" => %{name: "researcher", description: "web research agent"},
      "analyst" => %{name: "analyst", description: "data analysis agent"},
      "writer" => %{name: "writer", description: "content writing agent"}
    }
  end

  describe "Orchestrator lifecycle" do
    test "plans tasks, dispatches, collects results, converges" do
      # model_fn simulates LLM responses:
      # 1st call (initial_plan): returns 2 tasks
      # 2nd call (plan after t1): returns converge
      # 3rd call (converge): returns final text
      call_count = :counters.new(1, [:atomics])

      model_fn = fn _messages ->
        call = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, call)

        case call do
          1 ->
            {:ok,
             Jason.encode!([
               %{id: "t1", specialist: "researcher", input: "find data", priority: "high"},
               %{
                 id: "t2",
                 specialist: "analyst",
                 input: "analyze",
                 priority: "normal",
                 depends_on: ["t1"]
               }
             ])}

          2 ->
            {:ok, Jason.encode!(%{action: "converge"})}

          3 ->
            {:ok, "Final synthesized report based on all results."}
        end
      end

      {:ok, orch} =
        Orchestrator.start_link(
          model_client: fake_client(),
          specialists: fake_specialists(),
          max_concurrency: 2
        )

      # Run in a separate process since it blocks
      task =
        Task.async(fn ->
          Orchestrator.run(orch, "Analyze AAPL stock", model_fn: model_fn)
        end)

      # Give it a moment to plan and dispatch t1
      Process.sleep(100)

      # Simulate specialist completing t1
      Orchestrator.report_result(orch, "t1", "AAPL revenue is $94B", 5000)

      # Wait for convergence
      result = Task.await(task, 10_000)

      assert {:ok, final_text, summary} = result
      assert final_text =~ "Final synthesized report"
      assert summary.tasks_completed >= 1
    end

    test "respects max_iterations safety limit" do
      call_count = :counters.new(1, [:atomics])

      # model_fn: initial plan returns 1 task, re-eval always adds another,
      # converge returns final text
      model_fn = fn _messages ->
        call = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, call)

        cond do
          call == 1 ->
            {:ok,
             Jason.encode!([
               %{id: "t1", specialist: "researcher", input: "work", priority: "high"}
             ])}

          call <= 32 ->
            {:ok,
             Jason.encode!(%{
               action: "add",
               tasks: [
                 %{
                   id: "t#{call}",
                   specialist: "researcher",
                   input: "more work",
                   priority: "normal"
                 }
               ]
             })}

          true ->
            {:ok, "Final result after max iterations."}
        end
      end

      {:ok, orch} =
        Orchestrator.start_link(
          model_client: fake_client(),
          specialists: fake_specialists(),
          max_concurrency: 1
        )

      task =
        Task.async(fn ->
          Orchestrator.run(orch, "iteration limit test", model_fn: model_fn)
        end)

      Process.sleep(100)

      # Report results to keep the orchestrator iterating
      for i <- 1..31 do
        Orchestrator.report_result(orch, "t#{i}", "result #{i}", 100)
        Process.sleep(10)
      end

      result = Task.await(task, 15_000)
      assert {:ok, _text, summary} = result
      assert summary.iterations >= 1
    end
  end
end
