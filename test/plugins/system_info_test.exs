defmodule AgentEx.Plugins.SystemInfoTest do
  use ExUnit.Case, async: true

  alias AgentEx.Plugins.SystemInfo
  alias AgentEx.Tool

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = SystemInfo.manifest()
      assert manifest.name == "system"
      assert manifest.version == "1.0.0"
    end
  end

  describe "init/1" do
    test "returns four tools" do
      assert {:ok, tools} = SystemInfo.init(%{})
      names = Enum.map(tools, & &1.name)
      assert "env_var" in names
      assert "cwd" in names
      assert "datetime" in names
      assert "disk_usage" in names
    end

    test "all tools are :read kind" do
      {:ok, tools} = SystemInfo.init(%{})
      assert Enum.all?(tools, &(&1.kind == :read))
    end
  end

  describe "env_var tool" do
    test "reads existing env var" do
      {:ok, tools} = SystemInfo.init(%{})
      env = Enum.find(tools, &(&1.name == "env_var"))

      # PATH should always exist
      assert {:ok, value} = Tool.execute(env, %{"name" => "PATH"})
      assert is_binary(value)
      assert value != "Not set"
    end

    test "returns 'Not set' for missing env var" do
      {:ok, tools} = SystemInfo.init(%{})
      env = Enum.find(tools, &(&1.name == "env_var"))

      assert {:ok, "Not set"} =
               Tool.execute(env, %{"name" => "AGENT_EX_NONEXISTENT_VAR_XYZ_123"})
    end

    test "respects allowed_env_vars allowlist" do
      {:ok, tools} = SystemInfo.init(%{"allowed_env_vars" => ["HOME"]})
      env = Enum.find(tools, &(&1.name == "env_var"))

      assert {:ok, _} = Tool.execute(env, %{"name" => "HOME"})
      assert {:error, msg} = Tool.execute(env, %{"name" => "PATH"})
      assert msg =~ "not in allowed list"
    end
  end

  describe "cwd tool" do
    test "returns current working directory" do
      {:ok, tools} = SystemInfo.init(%{})
      cwd = Enum.find(tools, &(&1.name == "cwd"))

      assert {:ok, dir} = Tool.execute(cwd, %{})
      assert File.dir?(dir)
    end

    test "returns configured working_dir" do
      {:ok, tools} = SystemInfo.init(%{"working_dir" => "/tmp"})
      cwd = Enum.find(tools, &(&1.name == "cwd"))

      assert {:ok, "/tmp"} = Tool.execute(cwd, %{})
    end
  end

  describe "datetime tool" do
    test "returns iso8601 by default" do
      {:ok, tools} = SystemInfo.init(%{})
      dt = Enum.find(tools, &(&1.name == "datetime"))

      assert {:ok, result} = Tool.execute(dt, %{})
      # Should be parseable as ISO 8601
      assert {:ok, _, _} = DateTime.from_iso8601(result)
    end

    test "returns date only" do
      {:ok, tools} = SystemInfo.init(%{})
      dt = Enum.find(tools, &(&1.name == "datetime"))

      assert {:ok, result} = Tool.execute(dt, %{"format" => "date"})
      assert {:ok, _} = Date.from_iso8601(result)
    end

    test "returns time only" do
      {:ok, tools} = SystemInfo.init(%{})
      dt = Enum.find(tools, &(&1.name == "datetime"))

      assert {:ok, result} = Tool.execute(dt, %{"format" => "time"})
      assert {:ok, _} = Time.from_iso8601(result)
    end

    test "returns unix timestamp" do
      {:ok, tools} = SystemInfo.init(%{})
      dt = Enum.find(tools, &(&1.name == "datetime"))

      assert {:ok, result} = Tool.execute(dt, %{"format" => "unix"})
      {ts, ""} = Integer.parse(result)
      assert ts > 1_000_000_000
    end
  end

  describe "disk_usage tool" do
    test "returns disk usage info" do
      {:ok, tools} = SystemInfo.init(%{})
      disk = Enum.find(tools, &(&1.name == "disk_usage"))

      assert {:ok, result} = Tool.execute(disk, %{})
      parsed = Jason.decode!(result)
      assert is_binary(parsed["total"])
      assert is_binary(parsed["used"])
      assert is_binary(parsed["free"])
    end
  end
end
