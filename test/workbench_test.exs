defmodule AgentEx.WorkbenchTest do
  use ExUnit.Case, async: true

  alias AgentEx.Message.FunctionResult
  alias AgentEx.{Tool, Workbench}

  setup do
    {:ok, wb} = Workbench.start_link()

    tool =
      Tool.new(
        name: "greet",
        description: "Greet someone",
        parameters: %{},
        function: fn %{"name" => name} -> {:ok, "Hello, #{name}!"} end
      )

    %{wb: wb, tool: tool}
  end

  describe "add_tool/2" do
    test "adds a tool", %{wb: wb, tool: tool} do
      assert :ok = Workbench.add_tool(wb, tool)
      assert {:ok, ^tool} = Workbench.get_tool(wb, "greet")
    end

    test "rejects duplicate", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      assert {:error, :already_exists} = Workbench.add_tool(wb, tool)
    end
  end

  describe "remove_tool/2" do
    test "removes an existing tool", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      assert :ok = Workbench.remove_tool(wb, "greet")
      assert :not_found = Workbench.get_tool(wb, "greet")
    end

    test "returns error for unknown tool", %{wb: wb} do
      assert {:error, :not_found} = Workbench.remove_tool(wb, "nope")
    end
  end

  describe "update_tool/3" do
    test "updates tool fields", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      :ok = Workbench.update_tool(wb, "greet", description: "Say hello")
      {:ok, updated} = Workbench.get_tool(wb, "greet")
      assert updated.description == "Say hello"
    end

    test "returns error for unknown tool", %{wb: wb} do
      assert {:error, :not_found} = Workbench.update_tool(wb, "nope", description: "x")
    end
  end

  describe "list_tools/1" do
    test "returns all tools", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)

      tool2 =
        Tool.new(
          name: "farewell",
          description: "Say goodbye",
          parameters: %{},
          function: fn _ -> {:ok, "Bye!"} end
        )

      :ok = Workbench.add_tool(wb, tool2)

      tools = Workbench.list_tools(wb)
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["farewell", "greet"]
    end

    test "returns empty list when no tools", %{wb: wb} do
      assert Workbench.list_tools(wb) == []
    end
  end

  describe "call_tool/3" do
    test "executes a tool", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      result = Workbench.call_tool(wb, "greet", %{"name" => "World"})
      assert %FunctionResult{content: "Hello, World!", is_error: false} = result
    end

    test "returns error for unknown tool", %{wb: wb} do
      result = Workbench.call_tool(wb, "nope", %{})
      assert %FunctionResult{is_error: true} = result
      assert result.content =~ "unknown tool"
    end

    test "returns error when tool function fails", %{wb: wb} do
      failing_tool =
        Tool.new(
          name: "fail",
          description: "Always fails",
          parameters: %{},
          function: fn _ -> {:error, "boom"} end
        )

      :ok = Workbench.add_tool(wb, failing_tool)
      result = Workbench.call_tool(wb, "fail", %{})
      assert %FunctionResult{is_error: true} = result
    end
  end

  describe "version tracking" do
    test "version starts at 0", %{wb: wb} do
      assert Workbench.version(wb) == 0
    end

    test "version increments on add", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      assert Workbench.version(wb) == 1
    end

    test "version increments on remove", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      :ok = Workbench.remove_tool(wb, "greet")
      assert Workbench.version(wb) == 2
    end

    test "version increments on update", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      :ok = Workbench.update_tool(wb, "greet", description: "new")
      assert Workbench.version(wb) == 2
    end

    test "tools_if_changed returns tools when changed", %{wb: wb, tool: tool} do
      v0 = Workbench.version(wb)
      :ok = Workbench.add_tool(wb, tool)
      assert {:changed, tools, v1} = Workbench.tools_if_changed(wb, v0)
      assert length(tools) == 1
      assert v1 == 1
    end

    test "tools_if_changed returns unchanged when not changed", %{wb: wb, tool: tool} do
      :ok = Workbench.add_tool(wb, tool)
      v1 = Workbench.version(wb)
      assert :unchanged = Workbench.tools_if_changed(wb, v1)
    end
  end

  describe "add_override/3" do
    test "adds tool with overrides", %{wb: wb, tool: tool} do
      :ok = Workbench.add_override(wb, tool, name: "say_hello", description: "Say hi")
      {:ok, overridden} = Workbench.get_tool(wb, "say_hello")
      assert overridden.name == "say_hello"
      assert overridden.description == "Say hi"
    end

    test "overridden tool executes correctly", %{wb: wb, tool: tool} do
      :ok = Workbench.add_override(wb, tool, name: "say_hello")
      result = Workbench.call_tool(wb, "say_hello", %{"name" => "Alice"})
      assert result.content == "Hello, Alice!"
    end
  end

  describe "start_link with initial tools" do
    test "accepts tools option" do
      tool =
        Tool.new(
          name: "test",
          description: "Test",
          parameters: %{},
          function: fn _ -> {:ok, "ok"} end
        )

      {:ok, wb} = Workbench.start_link(tools: [tool])
      assert {:ok, _} = Workbench.get_tool(wb, "test")
    end
  end
end
