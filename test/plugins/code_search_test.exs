defmodule AgentEx.Plugins.CodeSearchTest do
  use ExUnit.Case, async: true

  alias AgentEx.Plugins.CodeSearch
  alias AgentEx.Tool

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agent_ex_search_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Create test file structure
    File.write!(Path.join(tmp_dir, "hello.ex"), """
    defmodule Hello do
      def greet(name) do
        "Hello, \#{name}!"
      end
    end
    """)

    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.write!(Path.join(tmp_dir, "lib/math.ex"), """
    defmodule Math do
      def add(a, b), do: a + b
      def subtract(a, b), do: a - b
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/math_test.exs"), """
    defmodule MathTest do
      use ExUnit.Case
      test "add" do
        assert Math.add(1, 2) == 3
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "README.md"), "# My Project\nSome docs here.\n")
    File.mkdir_p!(Path.join(tmp_dir, ".hidden"))
    File.write!(Path.join(tmp_dir, ".hidden/secret.txt"), "secret")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = CodeSearch.manifest()
      assert manifest.name == "search"
      assert manifest.version == "1.0.0"
      assert is_list(manifest.config_schema)
    end
  end

  describe "init/1" do
    test "returns three tools", %{tmp_dir: tmp_dir} do
      assert {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      names = Enum.map(tools, & &1.name)
      assert "find_files" in names
      assert "grep" in names
      assert "file_info" in names
    end

    test "raises on invalid root_path" do
      assert_raise ArgumentError, fn ->
        CodeSearch.init(%{"root_path" => "/nonexistent/path/surely"})
      end
    end
  end

  describe "find_files tool" do
    test "finds files by glob pattern", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      find = Enum.find(tools, &(&1.name == "find_files"))

      assert {:ok, result} = Tool.execute(find, %{"pattern" => "**/*.ex"})
      assert result =~ "hello.ex"
      assert result =~ "lib/math.ex"
      refute result =~ "math_test.exs"
    end

    test "finds files with specific extension", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      find = Enum.find(tools, &(&1.name == "find_files"))

      assert {:ok, result} = Tool.execute(find, %{"pattern" => "**/*.md"})
      assert result =~ "README.md"
    end

    test "does not include hidden files by default", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      find = Enum.find(tools, &(&1.name == "find_files"))

      assert {:ok, result} = Tool.execute(find, %{"pattern" => "**/*.txt"})
      refute result =~ "secret.txt"
    end

    test "includes hidden files when requested", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      find = Enum.find(tools, &(&1.name == "find_files"))

      assert {:ok, result} =
               Tool.execute(find, %{"pattern" => "**/*.txt", "include_hidden" => true})

      assert result =~ "secret.txt"
    end

    test "returns message when no files match", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      find = Enum.find(tools, &(&1.name == "find_files"))

      assert {:ok, result} = Tool.execute(find, %{"pattern" => "**/*.rs"})
      assert result =~ "No files found"
    end
  end

  describe "grep tool" do
    test "finds content matches", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      grep = Enum.find(tools, &(&1.name == "grep"))

      assert {:ok, result} = Tool.execute(grep, %{"pattern" => "defmodule"})
      assert result =~ "hello.ex"
      assert result =~ "lib/math.ex"
    end

    test "searches in specific file types", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      grep = Enum.find(tools, &(&1.name == "grep"))

      assert {:ok, result} =
               Tool.execute(grep, %{"pattern" => "defmodule", "file_pattern" => "**/*.exs"})

      assert result =~ "MathTest"
      refute result =~ "Hello"
    end

    test "case-insensitive search", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      grep = Enum.find(tools, &(&1.name == "grep"))

      assert {:ok, result} =
               Tool.execute(grep, %{"pattern" => "hello", "case_sensitive" => false})

      assert result =~ "hello.ex"
    end

    test "context lines", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      grep = Enum.find(tools, &(&1.name == "grep"))

      assert {:ok, result} =
               Tool.execute(grep, %{"pattern" => "greet", "context_lines" => 1})

      # Should include surrounding lines
      assert result =~ "defmodule Hello" or result =~ "Hello"
    end

    test "returns message when no matches found", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      grep = Enum.find(tools, &(&1.name == "grep"))

      assert {:ok, result} = Tool.execute(grep, %{"pattern" => "nonexistent_xyz_123"})
      assert result =~ "No matches found"
    end

    test "returns error for invalid regex", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      grep = Enum.find(tools, &(&1.name == "grep"))

      assert {:error, msg} = Tool.execute(grep, %{"pattern" => "[invalid"})
      assert msg =~ "Invalid regex"
    end
  end

  describe "file_info tool" do
    test "returns file metadata", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      info = Enum.find(tools, &(&1.name == "file_info"))

      assert {:ok, result} = Tool.execute(info, %{"path" => "hello.ex"})
      parsed = Jason.decode!(result)
      assert parsed["path"] == "hello.ex"
      assert parsed["type"] == "regular"
      assert is_integer(parsed["size"])
      assert parsed["size"] > 0
    end

    test "returns directory info", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      info = Enum.find(tools, &(&1.name == "file_info"))

      assert {:ok, result} = Tool.execute(info, %{"path" => "lib"})
      parsed = Jason.decode!(result)
      assert parsed["type"] == "directory"
    end

    test "returns error for nonexistent file", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      info = Enum.find(tools, &(&1.name == "file_info"))

      assert {:error, msg} = Tool.execute(info, %{"path" => "nope.txt"})
      assert msg =~ "Cannot stat"
    end

    test "blocks path traversal", %{tmp_dir: tmp_dir} do
      {:ok, tools} = CodeSearch.init(%{"root_path" => tmp_dir})
      info = Enum.find(tools, &(&1.name == "file_info"))

      assert {:error, msg} = Tool.execute(info, %{"path" => "../../etc/passwd"})
      assert msg =~ "path traversal"
    end
  end
end
