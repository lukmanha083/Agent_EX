defmodule AgentEx.Plugins.TodoTest do
  use ExUnit.Case, async: false

  alias AgentEx.Plugins.Todo
  alias AgentEx.Tool

  setup do
    # Ensure PluginSupervisor is running (started by application, but be safe)
    case DynamicSupervisor.start_link(name: AgentEx.PluginSupervisor, strategy: :one_for_one) do
      {:ok, _sup} -> :ok
      {:error, {:already_started, _sup}} -> :ok
    end

    # Start the Todo server under PluginSupervisor
    {:stateful, tools, child_spec} = Todo.init(%{})
    {:ok, pid} = DynamicSupervisor.start_child(AgentEx.PluginSupervisor, child_spec)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    end)

    %{tools: tools, server_pid: pid}
  end

  defp find_tool(tools, name), do: Enum.find(tools, &(&1.name == name))

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = Todo.manifest()
      assert manifest.name == "todo"
      assert manifest.version == "1.0.0"
    end
  end

  describe "init/1" do
    test "returns stateful result with 4 tools" do
      {:stateful, tools, child_spec} = Todo.init(%{})
      assert length(tools) == 4
      assert child_spec.id == Todo.Server
      names = Enum.map(tools, & &1.name)
      assert "add" in names
      assert "list" in names
      assert "update" in names
      assert "delete" in names
    end

    test "add and update and delete are :write, list is :read" do
      {:stateful, tools, _} = Todo.init(%{})
      assert find_tool(tools, "add").kind == :write
      assert find_tool(tools, "list").kind == :read
      assert find_tool(tools, "update").kind == :write
      assert find_tool(tools, "delete").kind == :write
    end
  end

  describe "add tool" do
    test "creates a todo and returns confirmation", %{tools: tools} do
      tool = find_tool(tools, "add")
      assert {:ok, msg} = Tool.execute(tool, %{"text" => "Write tests"})
      assert msg =~ "#1"
      assert msg =~ "Write tests"
    end

    test "assigns incrementing IDs", %{tools: tools} do
      tool = find_tool(tools, "add")
      assert {:ok, msg1} = Tool.execute(tool, %{"text" => "First"})
      assert {:ok, msg2} = Tool.execute(tool, %{"text" => "Second"})
      assert msg1 =~ "#1"
      assert msg2 =~ "#2"
    end
  end

  describe "list tool" do
    test "returns empty message when no todos", %{tools: tools} do
      tool = find_tool(tools, "list")
      assert {:ok, "No todos."} = Tool.execute(tool, %{})
    end

    test "lists all todos with status", %{tools: tools} do
      add = find_tool(tools, "add")
      list = find_tool(tools, "list")

      Tool.execute(add, %{"text" => "First task"})
      Tool.execute(add, %{"text" => "Second task"})

      assert {:ok, output} = Tool.execute(list, %{})
      assert output =~ "#1 [ ] First task"
      assert output =~ "#2 [ ] Second task"
    end

    test "shows correct status icons", %{tools: tools} do
      add = find_tool(tools, "add")
      update = find_tool(tools, "update")
      list = find_tool(tools, "list")

      Tool.execute(add, %{"text" => "Pending"})
      Tool.execute(add, %{"text" => "In progress"})
      Tool.execute(add, %{"text" => "Done"})

      Tool.execute(update, %{"id" => "2", "status" => "in_progress"})
      Tool.execute(update, %{"id" => "3", "status" => "done"})

      assert {:ok, output} = Tool.execute(list, %{})
      assert output =~ "#1 [ ] Pending"
      assert output =~ "#2 [~] In progress"
      assert output =~ "#3 [x] Done"
    end
  end

  describe "update tool" do
    test "changes status", %{tools: tools} do
      add = find_tool(tools, "add")
      update = find_tool(tools, "update")
      list = find_tool(tools, "list")

      Tool.execute(add, %{"text" => "My task"})
      assert {:ok, _} = Tool.execute(update, %{"id" => "1", "status" => "done"})

      assert {:ok, output} = Tool.execute(list, %{})
      assert output =~ "[x] My task"
    end

    test "changes text", %{tools: tools} do
      add = find_tool(tools, "add")
      update = find_tool(tools, "update")
      list = find_tool(tools, "list")

      Tool.execute(add, %{"text" => "Old description"})
      assert {:ok, _} = Tool.execute(update, %{"id" => "1", "text" => "New description"})

      assert {:ok, output} = Tool.execute(list, %{})
      assert output =~ "New description"
      refute output =~ "Old description"
    end

    test "returns error for unknown ID", %{tools: tools} do
      update = find_tool(tools, "update")
      assert {:error, msg} = Tool.execute(update, %{"id" => "999", "status" => "done"})
      assert msg =~ "#999 not found"
    end

    test "rejects invalid status values", %{tools: tools} do
      add = find_tool(tools, "add")
      update = find_tool(tools, "update")

      Tool.execute(add, %{"text" => "My task"})
      assert {:error, msg} = Tool.execute(update, %{"id" => "1", "status" => "completed"})
      assert msg =~ "Invalid status"
    end
  end

  describe "delete tool" do
    test "removes todo", %{tools: tools} do
      add = find_tool(tools, "add")
      delete = find_tool(tools, "delete")
      list = find_tool(tools, "list")

      Tool.execute(add, %{"text" => "To be deleted"})
      assert {:ok, _} = Tool.execute(delete, %{"id" => "1"})

      assert {:ok, "No todos."} = Tool.execute(list, %{})
    end

    test "returns error for unknown ID", %{tools: tools} do
      delete = find_tool(tools, "delete")
      assert {:error, msg} = Tool.execute(delete, %{"id" => "999"})
      assert msg =~ "#999 not found"
    end
  end

  describe "cleanup/1" do
    test "stops the server", %{server_pid: pid} do
      assert Process.alive?(pid)
      assert :ok = Todo.cleanup(pid)
      refute Process.alive?(pid)
    end

    test "handles nil pid gracefully" do
      assert :ok = Todo.cleanup(nil)
    end

    test "handles dead pid gracefully" do
      {:ok, pid} = Agent.start(fn -> :ok end)
      Agent.stop(pid)
      refute Process.alive?(pid)
      assert :ok = Todo.cleanup(pid)
    end
  end
end
