defmodule AgentEx.Plugins.FileSystemTest do
  use ExUnit.Case, async: true

  alias AgentEx.Plugins.FileSystem
  alias AgentEx.Tool

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agent_ex_fs_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "hello.txt"), "Hello, World!")
    File.mkdir_p!(Path.join(tmp_dir, "subdir"))
    File.write!(Path.join(tmp_dir, "subdir/nested.txt"), "Nested content")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = FileSystem.manifest()
      assert manifest.name == "filesystem"
      assert manifest.version == "1.0.0"
      assert is_list(manifest.config_schema)
    end
  end

  describe "init/1 (read-only)" do
    test "returns read tools", %{tmp_dir: tmp_dir} do
      assert {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir})
      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
      assert "list_dir" in names
      refute "write_file" in names
    end
  end

  describe "init/1 (with write)" do
    test "includes write tool when allow_write is true", %{tmp_dir: tmp_dir} do
      assert {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir, "allow_write" => true})
      names = Enum.map(tools, & &1.name)
      assert "write_file" in names
    end
  end

  describe "read_file tool" do
    test "reads a file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir})
      read_tool = Enum.find(tools, &(&1.name == "read_file"))

      assert {:ok, "Hello, World!"} = Tool.execute(read_tool, %{"path" => "hello.txt"})
    end

    test "reads nested file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir})
      read_tool = Enum.find(tools, &(&1.name == "read_file"))

      assert {:ok, "Nested content"} = Tool.execute(read_tool, %{"path" => "subdir/nested.txt"})
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir})
      read_tool = Enum.find(tools, &(&1.name == "read_file"))

      assert {:error, msg} = Tool.execute(read_tool, %{"path" => "nope.txt"})
      assert msg =~ "Cannot read"
    end
  end

  describe "list_dir tool" do
    test "lists root directory", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir})
      list_tool = Enum.find(tools, &(&1.name == "list_dir"))

      assert {:ok, output} = Tool.execute(list_tool, %{})
      assert output =~ "hello.txt"
      assert output =~ "subdir"
    end

    test "lists subdirectory", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir})
      list_tool = Enum.find(tools, &(&1.name == "list_dir"))

      assert {:ok, output} = Tool.execute(list_tool, %{"path" => "subdir"})
      assert output =~ "nested.txt"
    end
  end

  describe "write_file tool" do
    test "writes a file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir, "allow_write" => true})
      write_tool = Enum.find(tools, &(&1.name == "write_file"))

      assert {:ok, _} = Tool.execute(write_tool, %{"path" => "new.txt", "content" => "New file"})
      assert File.read!(Path.join(tmp_dir, "new.txt")) == "New file"
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir, "allow_write" => true})
      write_tool = Enum.find(tools, &(&1.name == "write_file"))

      assert {:ok, _} =
               Tool.execute(write_tool, %{"path" => "a/b/c.txt", "content" => "Deep"})

      assert File.read!(Path.join(tmp_dir, "a/b/c.txt")) == "Deep"
    end

    test "write tool has :write kind", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir, "allow_write" => true})
      write_tool = Enum.find(tools, &(&1.name == "write_file"))
      assert write_tool.kind == :write
    end
  end

  describe "path traversal protection" do
    test "blocks path traversal", %{tmp_dir: tmp_dir} do
      {:ok, tools} = FileSystem.init(%{"root_path" => tmp_dir})
      read_tool = Enum.find(tools, &(&1.name == "read_file"))

      assert {:error, msg} = Tool.execute(read_tool, %{"path" => "../../etc/passwd"})
      assert msg =~ "path traversal"
    end
  end
end
