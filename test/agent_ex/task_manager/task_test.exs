defmodule AgentEx.TaskManager.TaskTest do
  use AgentEx.DataCase, async: true

  alias AgentEx.TaskManager.Task

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Task.changeset(%Task{}, %{run_id: "run-1", title: "Fix bug"})
      assert cs.valid?
    end

    test "invalid without run_id" do
      cs = Task.changeset(%Task{}, %{title: "Fix bug"})
      refute cs.valid?
      assert %{run_id: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without title" do
      cs = Task.changeset(%Task{}, %{run_id: "run-1"})
      refute cs.valid?
      assert %{title: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid status" do
      cs = Task.changeset(%Task{}, %{run_id: "run-1", title: "X", status: "invalid"})
      refute cs.valid?
      assert %{status: _} = errors_on(cs)
    end

    test "invalid priority" do
      cs = Task.changeset(%Task{}, %{run_id: "run-1", title: "X", priority: "urgent"})
      refute cs.valid?
      assert %{priority: _} = errors_on(cs)
    end

    test "defaults" do
      cs = Task.changeset(%Task{}, %{run_id: "run-1", title: "X"})
      assert get_field(cs, :status) == "pending"
      assert get_field(cs, :priority) == "normal"
      assert get_field(cs, :depends_on) == []
      assert get_field(cs, :metadata) == %{}
      assert get_field(cs, :usage) == 0
    end
  end

  describe "update_changeset/2" do
    test "updates status" do
      task = %Task{run_id: "run-1", title: "X", status: "pending"}
      cs = Task.update_changeset(task, %{status: "in_progress"})
      assert cs.valid?
      assert get_change(cs, :status) == "in_progress"
    end

    test "rejects invalid status" do
      task = %Task{run_id: "run-1", title: "X", status: "pending"}
      cs = Task.update_changeset(task, %{status: "nope"})
      refute cs.valid?
    end

    test "does not allow changing run_id" do
      task = %Task{run_id: "run-1", title: "X"}
      cs = Task.update_changeset(task, %{run_id: "run-2"})
      assert get_change(cs, :run_id) == nil
    end
  end
end
