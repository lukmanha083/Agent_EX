defmodule AgentEx.Orchestrator.BudgetTrackerTest do
  use ExUnit.Case, async: true

  alias AgentEx.Orchestrator.BudgetTracker

  describe "new/1" do
    test "creates tracker with total budget" do
      bt = BudgetTracker.new(100_000)
      assert bt.total == 100_000
      assert bt.used == 0
      assert bt.zone == :explore
    end
  end

  describe "record/2 and remaining/1" do
    test "tracks usage" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(5_000)
      assert BudgetTracker.remaining(bt) == 95_000
      assert bt.task_count == 1
    end

    test "accumulates across multiple records" do
      bt =
        BudgetTracker.new(100_000)
        |> BudgetTracker.record(5_000)
        |> BudgetTracker.record(3_000)
        |> BudgetTracker.record(2_000)

      assert BudgetTracker.remaining(bt) == 90_000
      assert bt.task_count == 3
    end

    test "remaining never goes below zero" do
      bt = BudgetTracker.new(1_000) |> BudgetTracker.record(2_000)
      assert BudgetTracker.remaining(bt) == 0
    end
  end

  describe "zone transitions" do
    test "starts in explore zone" do
      bt = BudgetTracker.new(100_000)
      assert BudgetTracker.zone(bt) == :explore
    end

    test "transitions to focused at 50%" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(51_000)
      assert BudgetTracker.zone(bt) == :focused
    end

    test "transitions to converge at 20%" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(81_000)
      assert BudgetTracker.zone(bt) == :converge
    end

    test "transitions to report at 5%" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(96_000)
      assert BudgetTracker.zone(bt) == :report
    end
  end

  describe "velocity and projections" do
    test "velocity tracks EMA of usage" do
      bt =
        BudgetTracker.new(100_000)
        |> BudgetTracker.record(10_000)
        |> BudgetTracker.record(10_000)

      assert bt.velocity > 0
    end

    test "projected_tasks estimates remaining capacity" do
      bt =
        BudgetTracker.new(100_000)
        |> BudgetTracker.record(10_000)
        |> BudgetTracker.record(10_000)

      projected = BudgetTracker.projected_tasks(bt)
      assert projected > 0
      assert is_integer(projected)
    end

    test "projected_tasks with zero velocity returns remaining" do
      bt = BudgetTracker.new(100_000)
      assert BudgetTracker.projected_tasks(bt) == 100_000
    end
  end

  describe "max_concurrency_for_zone/2" do
    test "explore returns full base" do
      bt = BudgetTracker.new(100_000)
      assert BudgetTracker.max_concurrency_for_zone(bt, 4) == 4
    end

    test "focused returns half" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(51_000)
      assert BudgetTracker.max_concurrency_for_zone(bt, 4) == 2
    end

    test "converge returns 1" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(81_000)
      assert BudgetTracker.max_concurrency_for_zone(bt, 4) == 1
    end

    test "report returns 0" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(96_000)
      assert BudgetTracker.max_concurrency_for_zone(bt, 4) == 0
    end
  end

  describe "to_prompt/1" do
    test "generates readable prompt text" do
      bt =
        BudgetTracker.new(100_000)
        |> BudgetTracker.record(30_000)
        |> BudgetTracker.record(20_000)

      prompt = BudgetTracker.to_prompt(bt)
      assert prompt =~ "50000/100000"
      assert prompt =~ "50.0%"
      assert prompt =~ "Tasks completed: 2"
      assert prompt =~ "Zone: FOCUSED"
    end
  end

  describe "percent_remaining/1" do
    test "calculates percentage" do
      bt = BudgetTracker.new(100_000) |> BudgetTracker.record(25_000)
      assert BudgetTracker.percent_remaining(bt) == 75.0
    end
  end
end
