defmodule AgentEx.TaskManagerTest do
  use AgentEx.DataCase, async: false

  alias AgentEx.TaskManager

  setup do
    run_id = "test-run-#{System.unique_integer([:positive])}"
    %{run_id: run_id}
  end

  describe "create_task/2" do
    test "creates a task in DB and returns it", %{run_id: run_id} do
      assert {:ok, task} = TaskManager.create_task(run_id, %{title: "Fix auth bug"})
      assert task.id
      assert task.run_id == run_id
      assert task.title == "Fix auth bug"
      assert task.status == "pending"
      assert task.priority == "normal"
    end

    test "accepts optional fields", %{run_id: run_id} do
      attrs = %{
        title: "Deploy service",
        priority: "high",
        agent: "coder",
        specialist: "coder_agent",
        input: "Deploy the new auth service"
      }

      assert {:ok, task} = TaskManager.create_task(run_id, attrs)
      assert task.priority == "high"
      assert task.agent == "coder"
      assert task.specialist == "coder_agent"
      assert task.input == "Deploy the new auth service"
    end

    test "rejects invalid data" do
      assert {:error, cs} = TaskManager.create_task("run-1", %{})
      refute cs.valid?
    end
  end

  describe "get_task/1" do
    test "returns task by ID", %{run_id: run_id} do
      {:ok, task} = TaskManager.create_task(run_id, %{title: "Test"})
      assert found = TaskManager.get_task(task.id)
      assert found.id == task.id
      assert found.title == "Test"
    end

    test "returns nil for nonexistent ID" do
      assert TaskManager.get_task(999_999) == nil
    end
  end

  describe "update_task/2" do
    test "updates status and agent", %{run_id: run_id} do
      {:ok, task} = TaskManager.create_task(run_id, %{title: "Build API"})

      assert {:ok, updated} =
               TaskManager.update_task(task.id, %{status: "in_progress", agent: "coder"})

      assert updated.status == "in_progress"
      assert updated.agent == "coder"
    end

    test "updates result on completion", %{run_id: run_id} do
      {:ok, task} = TaskManager.create_task(run_id, %{title: "Analyze data"})

      assert {:ok, updated} =
               TaskManager.update_task(task.id, %{status: "completed", result: "Found 3 issues"})

      assert updated.status == "completed"
      assert updated.result == "Found 3 issues"
    end

    test "returns error for nonexistent task" do
      assert {:error, :not_found} = TaskManager.update_task(999_999, %{status: "completed"})
    end

    test "rejects invalid status", %{run_id: run_id} do
      {:ok, task} = TaskManager.create_task(run_id, %{title: "Test"})
      assert {:error, cs} = TaskManager.update_task(task.id, %{status: "invalid"})
      refute cs.valid?
    end
  end

  describe "list_tasks/1" do
    test "returns all tasks for a run in order", %{run_id: run_id} do
      {:ok, _} = TaskManager.create_task(run_id, %{title: "First"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Second"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Third"})

      tasks = TaskManager.list_tasks(run_id)
      assert length(tasks) == 3
      assert [%{title: "First"}, %{title: "Second"}, %{title: "Third"}] = tasks
    end

    test "returns empty list for unknown run" do
      assert TaskManager.list_tasks("nonexistent-run") == []
    end

    test "does not mix tasks from different runs", %{run_id: run_id} do
      other_run = "other-#{System.unique_integer([:positive])}"
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Mine"})
      {:ok, _} = TaskManager.create_task(other_run, %{title: "Theirs"})

      tasks = TaskManager.list_tasks(run_id)
      assert length(tasks) == 1
      assert hd(tasks).title == "Mine"
    end
  end

  describe "list_tasks/2 with filters" do
    test "filters by status", %{run_id: run_id} do
      {:ok, t1} = TaskManager.create_task(run_id, %{title: "A"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "B"})
      TaskManager.update_task(t1.id, %{status: "completed"})

      pending = TaskManager.list_tasks(run_id, status: "pending")
      assert length(pending) == 1
      assert hd(pending).title == "B"
    end

    test "filters by agent", %{run_id: run_id} do
      {:ok, t1} = TaskManager.create_task(run_id, %{title: "A"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "B"})
      TaskManager.update_task(t1.id, %{agent: "coder"})

      coder_tasks = TaskManager.list_tasks(run_id, agent: "coder")
      assert length(coder_tasks) == 1
      assert hd(coder_tasks).title == "A"
    end
  end

  describe "format_tasks/1" do
    test "formats empty run", %{run_id: run_id} do
      assert TaskManager.format_tasks(run_id) == "No tasks created yet."
    end

    test "formats tasks with status icons", %{run_id: run_id} do
      {:ok, t1} = TaskManager.create_task(run_id, %{title: "Plan"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Build"})
      TaskManager.update_task(t1.id, %{status: "completed", result: "Done"})

      output = TaskManager.format_tasks(run_id)
      assert output =~ "[x] Plan"
      assert output =~ "Result: Done"
      assert output =~ "[ ] Build"
    end
  end

  describe "ready_tasks/1" do
    test "returns pending tasks with no dependencies", %{run_id: run_id} do
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Independent"})
      ready = TaskManager.ready_tasks(run_id)
      assert length(ready) == 1
      assert hd(ready).title == "Independent"
    end

    test "blocks tasks with unmet dependencies", %{run_id: run_id} do
      {:ok, t1} = TaskManager.create_task(run_id, %{title: "First"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Second", depends_on: [t1.id]})

      ready = TaskManager.ready_tasks(run_id)
      assert length(ready) == 1
      assert hd(ready).title == "First"
    end

    test "unblocks tasks when dependencies complete", %{run_id: run_id} do
      {:ok, t1} = TaskManager.create_task(run_id, %{title: "First"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Second", depends_on: [t1.id]})

      TaskManager.update_task(t1.id, %{status: "completed"})

      ready = TaskManager.ready_tasks(run_id)
      assert length(ready) == 1
      assert hd(ready).title == "Second"
    end

    test "sorts by priority", %{run_id: run_id} do
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Low", priority: "low"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "High", priority: "high"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Normal"})

      ready = TaskManager.ready_tasks(run_id)
      assert Enum.map(ready, & &1.title) == ["High", "Normal", "Low"]
    end
  end

  describe "take_ready/2" do
    test "marks taken tasks as in_progress", %{run_id: run_id} do
      {:ok, _} = TaskManager.create_task(run_id, %{title: "A"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "B"})
      {:ok, _} = TaskManager.create_task(run_id, %{title: "C"})

      {taken, remaining} = TaskManager.take_ready(run_id, 2)
      assert length(taken) == 2
      assert remaining == 1
      assert Enum.all?(taken, &(&1.status == "in_progress"))
    end
  end

  describe "cache" do
    test "clear_cache removes from ETS but DB persists", %{run_id: run_id} do
      {:ok, task} = TaskManager.create_task(run_id, %{title: "Cached"})

      TaskManager.clear_cache(run_id)

      # DB still has it
      assert Repo.get(AgentEx.TaskManager.Task, task.id)

      # Cache is cold — list_tasks warms it from DB
      tasks = TaskManager.list_tasks(run_id)
      assert length(tasks) == 1
    end

    test "warm_cache loads from DB", %{run_id: run_id} do
      {:ok, _} = TaskManager.create_task(run_id, %{title: "Warm me"})
      TaskManager.clear_cache(run_id)

      tasks = TaskManager.warm_cache(run_id)
      assert length(tasks) == 1
      assert hd(tasks).title == "Warm me"
    end
  end
end
