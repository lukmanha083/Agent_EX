defmodule AgentEx.Plugins.TextEditorTest do
  use ExUnit.Case, async: true

  alias AgentEx.Plugins.TextEditor
  alias AgentEx.Tool

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agent_ex_editor_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "sample.txt"), """
    line one
    line two
    line three
    line four
    line five\
    """)

    File.write!(Path.join(tmp_dir, "code.ex"), """
    defmodule Foo do
      def bar do
        :ok
      end

      def baz do
        :error
      end
    end\
    """)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = TextEditor.manifest()
      assert manifest.name == "editor"
      assert manifest.version == "1.0.0"
    end
  end

  describe "init/1" do
    test "returns four tools", %{tmp_dir: tmp_dir} do
      assert {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      names = Enum.map(tools, & &1.name)
      assert "read" in names
      assert "edit" in names
      assert "insert" in names
      assert "append" in names
    end
  end

  describe "read tool" do
    test "reads file with line numbers", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:ok, result} = Tool.execute(read, %{"path" => "sample.txt"})
      assert result =~ "1\tline one"
      assert result =~ "2\tline two"
      assert result =~ "5\tline five"
    end

    test "reads with offset", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:ok, result} = Tool.execute(read, %{"path" => "sample.txt", "offset" => 3})
      refute result =~ "1\tline one"
      assert result =~ "3\tline three"
    end

    test "reads with limit", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:ok, result} = Tool.execute(read, %{"path" => "sample.txt", "limit" => 2})
      assert result =~ "1\tline one"
      assert result =~ "2\tline two"
      refute result =~ "3\tline three"
    end

    test "reads with offset and limit", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:ok, result} =
               Tool.execute(read, %{"path" => "sample.txt", "offset" => 2, "limit" => 2})

      refute result =~ "1\tline one"
      assert result =~ "2\tline two"
      assert result =~ "3\tline three"
      refute result =~ "4\tline four"
    end

    test "returns error for nonexistent file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:error, msg} = Tool.execute(read, %{"path" => "nope.txt"})
      assert msg =~ "File not found"
    end

    test "shows header with line range", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:ok, result} = Tool.execute(read, %{"path" => "sample.txt"})
      assert result =~ "[sample.txt]"
    end
  end

  describe "edit tool" do
    test "replaces unique string", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      edit = Enum.find(tools, &(&1.name == "edit"))

      assert {:ok, msg} =
               Tool.execute(edit, %{
                 "path" => "sample.txt",
                 "old_string" => "line two",
                 "new_string" => "line TWO"
               })

      assert msg =~ "Replaced 1"
      assert File.read!(Path.join(tmp_dir, "sample.txt")) =~ "line TWO"
    end

    test "errors when old_string not found", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      edit = Enum.find(tools, &(&1.name == "edit"))

      assert {:error, msg} =
               Tool.execute(edit, %{
                 "path" => "sample.txt",
                 "old_string" => "nonexistent",
                 "new_string" => "replacement"
               })

      assert msg =~ "not found"
    end

    test "errors on ambiguous match without replace_all", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      edit = Enum.find(tools, &(&1.name == "edit"))

      # "line" appears in every line
      assert {:error, msg} =
               Tool.execute(edit, %{
                 "path" => "sample.txt",
                 "old_string" => "line",
                 "new_string" => "LINE"
               })

      assert msg =~ "occurrences"
    end

    test "replace_all replaces all occurrences", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      edit = Enum.find(tools, &(&1.name == "edit"))

      assert {:ok, msg} =
               Tool.execute(edit, %{
                 "path" => "sample.txt",
                 "old_string" => "line",
                 "new_string" => "LINE",
                 "replace_all" => true
               })

      assert msg =~ "Replaced 5"
      content = File.read!(Path.join(tmp_dir, "sample.txt"))
      assert content =~ "LINE one"
      assert content =~ "LINE five"
    end

    test "edit has :write kind", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      edit = Enum.find(tools, &(&1.name == "edit"))
      assert edit.kind == :write
    end
  end

  describe "insert tool" do
    test "inserts before a specific line", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      insert = Enum.find(tools, &(&1.name == "insert"))

      assert {:ok, _} =
               Tool.execute(insert, %{
                 "path" => "sample.txt",
                 "line" => 3,
                 "text" => "INSERTED"
               })

      content = File.read!(Path.join(tmp_dir, "sample.txt"))
      lines = String.split(content, "\n")
      assert Enum.at(lines, 2) == "INSERTED"
      assert Enum.at(lines, 3) == "line three"
    end

    test "inserts at beginning with line 0", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      insert = Enum.find(tools, &(&1.name == "insert"))

      assert {:ok, _} =
               Tool.execute(insert, %{
                 "path" => "sample.txt",
                 "line" => 0,
                 "text" => "FIRST"
               })

      content = File.read!(Path.join(tmp_dir, "sample.txt"))
      assert String.starts_with?(content, "FIRST\n")
    end

    test "insert has :write kind", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      insert = Enum.find(tools, &(&1.name == "insert"))
      assert insert.kind == :write
    end
  end

  describe "append tool" do
    test "appends to existing file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      append = Enum.find(tools, &(&1.name == "append"))

      assert {:ok, _} = Tool.execute(append, %{"path" => "sample.txt", "text" => "\nline six"})

      content = File.read!(Path.join(tmp_dir, "sample.txt"))
      assert content =~ "line six"
    end

    test "creates new file if it doesn't exist", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      append = Enum.find(tools, &(&1.name == "append"))

      assert {:ok, _} = Tool.execute(append, %{"path" => "new.txt", "text" => "brand new"})

      assert File.read!(Path.join(tmp_dir, "new.txt")) == "brand new"
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      append = Enum.find(tools, &(&1.name == "append"))

      assert {:ok, _} =
               Tool.execute(append, %{"path" => "a/b/deep.txt", "text" => "deep content"})

      assert File.read!(Path.join(tmp_dir, "a/b/deep.txt")) == "deep content"
    end

    test "append has :write kind", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      append = Enum.find(tools, &(&1.name == "append"))
      assert append.kind == :write
    end
  end

  describe "path traversal protection" do
    test "blocks traversal on read", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:error, msg} = Tool.execute(read, %{"path" => "../../etc/passwd"})
      assert msg =~ "path traversal"
    end

    test "blocks traversal on edit", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      edit = Enum.find(tools, &(&1.name == "edit"))

      assert {:error, msg} =
               Tool.execute(edit, %{
                 "path" => "../../etc/shadow",
                 "old_string" => "x",
                 "new_string" => "y"
               })

      assert msg =~ "path traversal"
    end

    test "blocks traversal on insert", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      insert = Enum.find(tools, &(&1.name == "insert"))

      assert {:error, msg} =
               Tool.execute(insert, %{
                 "path" => "../../tmp/bad.txt",
                 "line" => 1,
                 "text" => "bad"
               })

      assert msg =~ "path traversal"
    end

    test "blocks traversal on append", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      append = Enum.find(tools, &(&1.name == "append"))

      assert {:error, msg} =
               Tool.execute(append, %{"path" => "../../tmp/bad.txt", "text" => "bad"})

      assert msg =~ "path traversal"
    end

    test "blocks absolute path on read", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      read = Enum.find(tools, &(&1.name == "read"))

      assert {:error, msg} = Tool.execute(read, %{"path" => "/etc/passwd"})
      assert msg =~ "absolute paths not allowed"
      assert msg =~ "/etc/passwd"
    end

    test "blocks absolute path on edit", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      edit = Enum.find(tools, &(&1.name == "edit"))

      assert {:error, msg} =
               Tool.execute(edit, %{
                 "path" => "/etc/shadow",
                 "old_string" => "x",
                 "new_string" => "y"
               })

      assert msg =~ "absolute paths not allowed"
      assert msg =~ "/etc/shadow"
    end

    test "blocks absolute path on insert", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      insert = Enum.find(tools, &(&1.name == "insert"))

      assert {:error, msg} =
               Tool.execute(insert, %{
                 "path" => "/tmp/bad.txt",
                 "line" => 1,
                 "text" => "bad"
               })

      assert msg =~ "absolute paths not allowed"
      assert msg =~ "/tmp/bad.txt"
    end

    test "blocks absolute path on append", %{tmp_dir: tmp_dir} do
      {:ok, tools} = TextEditor.init(%{"root_path" => tmp_dir})
      append = Enum.find(tools, &(&1.name == "append"))

      assert {:error, msg} =
               Tool.execute(append, %{"path" => "/tmp/bad.txt", "text" => "bad"})

      assert msg =~ "absolute paths not allowed"
      assert msg =~ "/tmp/bad.txt"
    end
  end
end
