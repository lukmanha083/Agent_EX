defmodule AgentEx.Orchestrator.TaskQueueTest do
  use ExUnit.Case, async: true

  alias AgentEx.Orchestrator.TaskQueue

  setup do
    {:ok, queue: TaskQueue.new()}
  end

  describe "push/take basics" do
    test "push and take a single task", %{queue: q} do
      q = TaskQueue.push(q, %{id: "t1", specialist: "researcher", input: "find AAPL"})

      {taken, remaining} = TaskQueue.take(q, 1)
      assert length(taken) == 1
      assert hd(taken).id == "t1"
      assert TaskQueue.pending_count(remaining) == 0
    end

    test "take respects limit", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "t1", specialist: "a", input: "x"})
        |> TaskQueue.push(%{id: "t2", specialist: "b", input: "y"})
        |> TaskQueue.push(%{id: "t3", specialist: "c", input: "z"})

      {taken, remaining} = TaskQueue.take(q, 2)
      assert length(taken) == 2
      assert TaskQueue.pending_count(remaining) == 1
    end

    test "empty queue returns no tasks", %{queue: q} do
      {taken, _} = TaskQueue.take(q, 5)
      assert taken == []
    end
  end

  describe "priority ordering" do
    test "high priority taken before normal and low", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "low", specialist: "a", input: "x", priority: :low})
        |> TaskQueue.push(%{id: "high", specialist: "b", input: "y", priority: :high})
        |> TaskQueue.push(%{id: "normal", specialist: "c", input: "z", priority: :normal})

      {taken, _} = TaskQueue.take(q, 3)
      ids = Enum.map(taken, & &1.id)
      assert ids == ["high", "normal", "low"]
    end
  end

  describe "dependency tracking" do
    test "blocked tasks are not taken", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "t1", specialist: "a", input: "x"})
        |> TaskQueue.push(%{id: "t2", specialist: "b", input: "y", depends_on: ["t1"]})

      {taken, remaining} = TaskQueue.take(q, 5)
      assert length(taken) == 1
      assert hd(taken).id == "t1"
      assert TaskQueue.pending_count(remaining) == 1
    end

    test "tasks unblock when dependencies complete", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "t1", specialist: "a", input: "x"})
        |> TaskQueue.push(%{id: "t2", specialist: "b", input: "y", depends_on: ["t1"]})

      # t1 is ready, t2 is blocked
      {[t1], q} = TaskQueue.take(q, 5)
      assert t1.id == "t1"

      # Mark t1 as completed, now t2 should be ready
      completed = MapSet.new(["t1"])
      {[t2], _} = TaskQueue.take(q, 5, completed)
      assert t2.id == "t2"
    end

    test "multi-dependency blocks until all complete", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "t1", specialist: "a", input: "x"})
        |> TaskQueue.push(%{id: "t2", specialist: "b", input: "y"})
        |> TaskQueue.push(%{id: "t3", specialist: "c", input: "z", depends_on: ["t1", "t2"]})

      # Only t1 completed — t3 still blocked
      {taken, _} = TaskQueue.take(q, 5, MapSet.new(["t1"]))
      ids = Enum.map(taken, & &1.id)
      assert "t3" not in ids

      # Both completed — t3 ready
      {taken, _} = TaskQueue.take(q, 5, MapSet.new(["t1", "t2"]))
      ids = Enum.map(taken, & &1.id)
      assert "t3" in ids
    end
  end

  describe "drop" do
    test "drop removes a task by ID", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "t1", specialist: "a", input: "x"})
        |> TaskQueue.push(%{id: "t2", specialist: "b", input: "y"})
        |> TaskQueue.drop("t1")

      assert TaskQueue.pending_count(q) == 1
      assert TaskQueue.task_ids(q) == ["t2"]
    end

    test "drop_many removes multiple tasks", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "t1", specialist: "a", input: "x"})
        |> TaskQueue.push(%{id: "t2", specialist: "b", input: "y"})
        |> TaskQueue.push(%{id: "t3", specialist: "c", input: "z"})
        |> TaskQueue.drop_many(["t1", "t3"])

      assert TaskQueue.pending_count(q) == 1
      assert TaskQueue.task_ids(q) == ["t2"]
    end
  end

  describe "reorder" do
    test "changing priority affects take order", %{queue: q} do
      q =
        q
        |> TaskQueue.push(%{id: "t1", specialist: "a", input: "x", priority: :low})
        |> TaskQueue.push(%{id: "t2", specialist: "b", input: "y", priority: :normal})
        |> TaskQueue.reorder("t1", :high)

      {taken, _} = TaskQueue.take(q, 2)
      assert hd(taken).id == "t1"
    end
  end

  describe "has_ready_tasks?" do
    test "returns true when ready tasks exist", %{queue: q} do
      q = TaskQueue.push(q, %{id: "t1", specialist: "a", input: "x"})
      assert TaskQueue.has_ready_tasks?(q, MapSet.new())
    end

    test "returns false when all tasks are blocked", %{queue: q} do
      q = TaskQueue.push(q, %{id: "t1", specialist: "a", input: "x", depends_on: ["t0"]})
      refute TaskQueue.has_ready_tasks?(q, MapSet.new())
    end

    test "returns true when blocked task is unblocked", %{queue: q} do
      q = TaskQueue.push(q, %{id: "t1", specialist: "a", input: "x", depends_on: ["t0"]})
      assert TaskQueue.has_ready_tasks?(q, MapSet.new(["t0"]))
    end
  end

  describe "push_many" do
    test "pushes multiple tasks at once", %{queue: q} do
      tasks = [
        %{id: "t1", specialist: "a", input: "x"},
        %{id: "t2", specialist: "b", input: "y"},
        %{id: "t3", specialist: "c", input: "z"}
      ]

      q = TaskQueue.push_many(q, tasks)
      assert TaskQueue.pending_count(q) == 3
    end
  end
end
