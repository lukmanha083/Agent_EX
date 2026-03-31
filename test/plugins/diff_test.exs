defmodule AgentEx.Plugins.DiffTest do
  use ExUnit.Case, async: true

  alias AgentEx.Plugins.Diff
  alias AgentEx.Tool

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agent_ex_diff_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "original.txt"), """
    line one
    line two
    line three
    line four
    line five\
    """)

    File.write!(Path.join(tmp_dir, "modified.txt"), """
    line one
    line TWO
    line three
    line 3.5
    line four
    line five\
    """)

    File.write!(Path.join(tmp_dir, "identical.txt"), """
    line one
    line two
    line three
    line four
    line five\
    """)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = Diff.manifest()
      assert manifest.name == "diff"
      assert manifest.version == "1.0.0"
    end
  end

  describe "init/1" do
    test "returns two tools", %{tmp_dir: tmp_dir} do
      assert {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      names = Enum.map(tools, & &1.name)
      assert "compare_files" in names
      assert "compare_text" in names
    end

    test "all tools are :read kind", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      assert Enum.all?(tools, &(&1.kind == :read))
    end
  end

  describe "compare_files tool" do
    test "shows differences between files", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      compare = Enum.find(tools, &(&1.name == "compare_files"))

      assert {:ok, result} =
               Tool.execute(compare, %{
                 "file_a" => "original.txt",
                 "file_b" => "modified.txt"
               })

      assert result =~ "---"
      assert result =~ "+++"
      assert result =~ "@@"
    end

    test "reports identical files", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      compare = Enum.find(tools, &(&1.name == "compare_files"))

      assert {:ok, result} =
               Tool.execute(compare, %{
                 "file_a" => "original.txt",
                 "file_b" => "identical.txt"
               })

      assert result == "Files are identical"
    end

    test "returns error for nonexistent file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      compare = Enum.find(tools, &(&1.name == "compare_files"))

      assert {:error, msg} =
               Tool.execute(compare, %{
                 "file_a" => "original.txt",
                 "file_b" => "nope.txt"
               })

      assert msg =~ "File not found"
    end

    test "blocks path traversal", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      compare = Enum.find(tools, &(&1.name == "compare_files"))

      assert {:error, msg} =
               Tool.execute(compare, %{
                 "file_a" => "../../etc/passwd",
                 "file_b" => "original.txt"
               })

      assert msg =~ "path traversal"
    end
  end

  describe "compare_text tool" do
    test "shows differences between texts", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      compare = Enum.find(tools, &(&1.name == "compare_text"))

      assert {:ok, result} =
               Tool.execute(compare, %{
                 "text_a" => "hello\nworld",
                 "text_b" => "hello\nearth"
               })

      assert result =~ "-world"
      assert result =~ "+earth"
    end

    test "reports identical texts", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      compare = Enum.find(tools, &(&1.name == "compare_text"))

      assert {:ok, result} =
               Tool.execute(compare, %{
                 "text_a" => "same text",
                 "text_b" => "same text"
               })

      assert result == "Texts are identical"
    end

    test "supports custom labels", %{tmp_dir: tmp_dir} do
      {:ok, tools} = Diff.init(%{"root_path" => tmp_dir})
      compare = Enum.find(tools, &(&1.name == "compare_text"))

      assert {:ok, result} =
               Tool.execute(compare, %{
                 "text_a" => "old",
                 "text_b" => "new",
                 "label_a" => "before",
                 "label_b" => "after"
               })

      assert result =~ "--- before"
      assert result =~ "+++ after"
    end
  end
end
