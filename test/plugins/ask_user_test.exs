defmodule AgentEx.Plugins.AskUserTest do
  use ExUnit.Case, async: true

  alias AgentEx.Plugins.AskUser
  alias AgentEx.Tool

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = AskUser.manifest()
      assert manifest.name == "ask_user"
      assert manifest.version == "1.0.0"
      assert manifest.config_schema == []
    end
  end

  describe "init/1" do
    test "returns one tool" do
      {:ok, tools} = AskUser.init(%{})
      assert length(tools) == 1
      assert hd(tools).name == "question"
    end

    test "tool is :write kind" do
      {:ok, [tool]} = AskUser.init(%{})
      assert tool.kind == :write
    end
  end

  describe "question tool" do
    test "calls handler and returns answer" do
      handler = fn question ->
        assert question == "What color?"
        {:ok, "blue"}
      end

      {:ok, [tool]} = AskUser.init(%{"handler" => handler})
      assert {:ok, "blue"} = Tool.execute(tool, %{"question" => "What color?"})
    end

    test "returns error when handler returns {:error, reason}" do
      handler = fn _question -> {:error, :timeout} end
      {:ok, [tool]} = AskUser.init(%{"handler" => handler})
      assert {:error, msg} = Tool.execute(tool, %{"question" => "Hello?"})
      assert msg =~ "User interaction failed"
    end

    test "default handler returns error when no handler configured" do
      {:ok, [tool]} = AskUser.init(%{})
      assert {:error, msg} = Tool.execute(tool, %{"question" => "Hello?"})
      assert msg =~ "No handler configured"
    end

    test "returns error for unexpected handler return" do
      handler = fn _question -> :ok end
      {:ok, [tool]} = AskUser.init(%{"handler" => handler})
      assert {:error, msg} = Tool.execute(tool, %{"question" => "Hello?"})
      assert msg =~ "unexpected value"
    end

    test "includes context in prompt when provided" do
      handler = fn prompt ->
        assert prompt =~ "[Need to pick a database]"
        assert prompt =~ "PostgreSQL or SQLite?"
        {:ok, "PostgreSQL"}
      end

      {:ok, [tool]} = AskUser.init(%{"handler" => handler})

      assert {:ok, "PostgreSQL"} =
               Tool.execute(tool, %{
                 "question" => "PostgreSQL or SQLite?",
                 "context" => "Need to pick a database"
               })
    end

    test "omits context prefix when not provided" do
      handler = fn prompt ->
        refute prompt =~ "["
        {:ok, "sure"}
      end

      {:ok, [tool]} = AskUser.init(%{"handler" => handler})
      assert {:ok, "sure"} = Tool.execute(tool, %{"question" => "Continue?"})
    end
  end
end
