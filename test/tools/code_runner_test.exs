defmodule AgentEx.Tools.CodeRunnerTest do
  use ExUnit.Case, async: true

  alias AgentEx.Tools.CodeRunner

  describe "tool/1" do
    test "returns a valid Tool struct" do
      tool = CodeRunner.tool()
      assert tool.name == "code_runner"
      assert tool.kind == :write
      assert is_function(tool.function, 1)
    end

    test "accepts lang and timeout options" do
      tool = CodeRunner.tool(lang: :bash, timeout: 5_000)
      assert tool.description =~ "bash"
    end
  end

  describe "execution" do
    test "runs elixir code" do
      tool = CodeRunner.tool(lang: :elixir)
      assert {:ok, "42"} = AgentEx.Tool.execute(tool, %{"code" => "IO.puts(42)"})
    end

    test "runs bash code" do
      tool = CodeRunner.tool(lang: :bash)
      assert {:ok, "hello"} = AgentEx.Tool.execute(tool, %{"code" => "echo hello"})
    end

    test "returns error on non-zero exit" do
      tool = CodeRunner.tool(lang: :bash)
      assert {:error, msg} = AgentEx.Tool.execute(tool, %{"code" => "exit 1"})
      assert msg =~ "Exit code 1"
    end

    test "handles timeout" do
      tool = CodeRunner.tool(lang: :bash, timeout: 200)
      assert {:error, msg} = AgentEx.Tool.execute(tool, %{"code" => "sleep 10"})
      assert msg =~ "timed out"
    end
  end
end
