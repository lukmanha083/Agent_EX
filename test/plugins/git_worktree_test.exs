defmodule AgentEx.Plugins.GitWorktreeTest do
  use ExUnit.Case, async: false

  alias AgentEx.Plugins.GitWorktree
  alias AgentEx.Plugins.GitWorktree.Coordinator
  alias AgentEx.Plugins.GitWorktree.Coordinator.WorktreeInfo

  @moduletag :git_worktree

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agent_ex_wt_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    System.cmd("git", ["init", "--initial-branch", "main"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    File.write!(Path.join(tmp_dir, "README.md"), "# Test repo")
    System.cmd("git", ["add", "."], cd: tmp_dir)
    System.cmd("git", ["commit", "-m", "initial commit"], cd: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{repo: tmp_dir}
  end

  # -- Coordinator tests --

  describe "Coordinator.start_link/1" do
    test "starts with valid repo", %{repo: repo} do
      assert {:ok, pid} = Coordinator.start_link(repo_root: repo)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "detects base branch", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)
      state = :sys.get_state(pid)
      assert state.base_branch == "main"
      GenServer.stop(pid)
    end
  end

  describe "Coordinator.create/3" do
    test "creates a worktree", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:ok, %WorktreeInfo{} = info} = Coordinator.create(pid, "agent-1")
      assert info.name == "agent-1"
      assert info.branch == "worktree/agent-1"
      assert File.dir?(info.path)
      assert info.agent_id == "agent-1"
      assert %DateTime{} = info.created_at

      GenServer.stop(pid)
    end

    test "creates multiple worktrees", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:ok, info_a} = Coordinator.create(pid, "agent-a")
      assert {:ok, info_b} = Coordinator.create(pid, "agent-b")

      assert info_a.path != info_b.path
      assert info_a.branch != info_b.branch
      assert File.dir?(info_a.path)
      assert File.dir?(info_b.path)

      GenServer.stop(pid)
    end

    test "rejects duplicate worktree name", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:ok, _} = Coordinator.create(pid, "agent-1")
      assert {:error, {:already_exists, "agent-1"}} = Coordinator.create(pid, "agent-1")

      GenServer.stop(pid)
    end

    test "custom agent_id", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:ok, info} = Coordinator.create(pid, "wt-1", agent_id: "custom-agent")
      assert info.agent_id == "custom-agent"

      GenServer.stop(pid)
    end
  end

  describe "Coordinator.list/1" do
    test "lists all active worktrees", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      Coordinator.create(pid, "agent-a")
      Coordinator.create(pid, "agent-b")

      worktrees = Coordinator.list(pid)
      assert length(worktrees) == 2
      names = Enum.map(worktrees, & &1.name) |> Enum.sort()
      assert names == ["agent-a", "agent-b"]

      GenServer.stop(pid)
    end

    test "empty when no worktrees", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)
      assert [] = Coordinator.list(pid)
      GenServer.stop(pid)
    end
  end

  describe "Coordinator.status/2" do
    test "reports clean status", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)
      {:ok, info} = Coordinator.create(pid, "agent-1")

      assert {:ok, status} = Coordinator.status(pid, "agent-1")
      assert status.branch == "worktree/agent-1"
      assert status.path == info.path
      assert status.uncommitted_changes == []
      assert status.has_changes == false

      GenServer.stop(pid)
    end

    test "detects uncommitted changes", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)
      {:ok, info} = Coordinator.create(pid, "agent-1")

      File.write!(Path.join(info.path, "new_file.txt"), "hello")

      assert {:ok, status} = Coordinator.status(pid, "agent-1")
      assert status.has_changes == true
      assert status.uncommitted_changes != []

      GenServer.stop(pid)
    end

    test "returns error for unknown worktree", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:not_found, "nope"}} = Coordinator.status(pid, "nope")

      GenServer.stop(pid)
    end
  end

  describe "Coordinator.merge/3" do
    test "merges worktree branch into target", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      System.cmd("git", ["branch", "rolling"], cd: repo)

      {:ok, info} = Coordinator.create(pid, "agent-1", base_branch: "rolling")

      File.write!(Path.join(info.path, "feature.txt"), "new feature")
      System.cmd("git", ["add", "."], cd: info.path)
      System.cmd("git", ["commit", "-m", "add feature"], cd: info.path)

      assert :ok = Coordinator.merge(pid, "agent-1", "rolling")

      System.cmd("git", ["checkout", "rolling"], cd: repo)
      assert File.exists?(Path.join(repo, "feature.txt"))

      GenServer.stop(pid)
    end

    test "reports conflicts", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      System.cmd("git", ["branch", "rolling"], cd: repo)

      {:ok, info} = Coordinator.create(pid, "agent-1", base_branch: "rolling")

      rolling_wt =
        Path.join(System.tmp_dir!(), "rolling_wt_#{System.unique_integer([:positive])}")

      System.cmd("git", ["worktree", "add", rolling_wt, "rolling"], cd: repo)
      File.write!(Path.join(rolling_wt, "conflict.txt"), "rolling version")
      System.cmd("git", ["add", "."], cd: rolling_wt)
      System.cmd("git", ["commit", "-m", "rolling change"], cd: rolling_wt)
      System.cmd("git", ["worktree", "remove", "--force", rolling_wt], cd: repo)

      File.write!(Path.join(info.path, "conflict.txt"), "agent version")
      System.cmd("git", ["add", "."], cd: info.path)
      System.cmd("git", ["commit", "-m", "agent change"], cd: info.path)

      assert {:error, {:conflict, _files}} = Coordinator.merge(pid, "agent-1", "rolling")

      GenServer.stop(pid)
    end
  end

  describe "Coordinator.delete/3" do
    test "deletes a worktree", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      {:ok, info} = Coordinator.create(pid, "agent-1")
      assert File.dir?(info.path)

      assert :ok = Coordinator.delete(pid, "agent-1")
      refute File.dir?(info.path)
      assert [] = Coordinator.list(pid)

      GenServer.stop(pid)
    end

    test "force deletes dirty worktree", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      {:ok, info} = Coordinator.create(pid, "agent-1")
      File.write!(Path.join(info.path, "dirty.txt"), "uncommitted")

      assert :ok = Coordinator.delete(pid, "agent-1", force: true)
      assert [] = Coordinator.list(pid)

      GenServer.stop(pid)
    end

    test "returns error for unknown worktree", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:not_found, "nope"}} = Coordinator.delete(pid, "nope")

      GenServer.stop(pid)
    end
  end

  describe "Coordinator.terminate/2 (auto_cleanup)" do
    test "cleans up worktrees on stop", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo, auto_cleanup: true)

      {:ok, info_a} = Coordinator.create(pid, "agent-a")
      {:ok, info_b} = Coordinator.create(pid, "agent-b")

      GenServer.stop(pid, :normal)

      refute File.dir?(info_a.path)
      refute File.dir?(info_b.path)
    end

    test "skips cleanup when auto_cleanup is false", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo, auto_cleanup: false)

      {:ok, info} = Coordinator.create(pid, "agent-1")
      GenServer.stop(pid, :normal)

      assert File.dir?(info.path)

      System.cmd("git", ["worktree", "remove", "--force", info.path], cd: repo)
      System.cmd("git", ["worktree", "prune"], cd: repo)
    end
  end

  describe "Coordinator.ensure_branch/3" do
    test "creates branch if missing", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert :ok = Coordinator.ensure_branch(pid, "rolling")

      {output, 0} = System.cmd("git", ["branch", "--list", "rolling"], cd: repo)
      assert String.contains?(output, "rolling")

      GenServer.stop(pid)
    end

    test "no-op if branch exists", %{repo: repo} do
      System.cmd("git", ["branch", "rolling"], cd: repo)
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert :ok = Coordinator.ensure_branch(pid, "rolling")

      GenServer.stop(pid)
    end
  end

  describe "concurrent worktree operations" do
    test "parallel commits in different worktrees don't conflict", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      {:ok, info_a} = Coordinator.create(pid, "agent-a")
      {:ok, info_b} = Coordinator.create(pid, "agent-b")
      {:ok, info_c} = Coordinator.create(pid, "agent-c")

      tasks =
        [info_a, info_b, info_c]
        |> Enum.map(fn info ->
          Task.async(fn ->
            file = Path.join(info.path, "#{info.name}.txt")
            File.write!(file, "work from #{info.name}")
            System.cmd("git", ["add", "."], cd: info.path)

            System.cmd("git", ["commit", "-m", "commit from #{info.name}"], cd: info.path)
          end)
        end)

      results = Task.await_many(tasks, 15_000)

      Enum.each(results, fn {_output, code} ->
        assert code == 0
      end)

      {_output, 0} = System.cmd("git", ["fsck", "--no-dangling"], cd: repo)

      GenServer.stop(pid)
    end
  end

  # -- Security tests --

  describe "path traversal protection" do
    test "rejects name with path traversal", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "../../.ssh")
      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "../escape")
      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "a/b")
      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "a\\b")

      GenServer.stop(pid)
    end

    test "rejects dot names", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, ".")
      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "..")
      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, ".hidden")

      GenServer.stop(pid)
    end

    test "rejects empty name", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "")

      GenServer.stop(pid)
    end
  end

  describe "git flag injection protection" do
    test "rejects name starting with dash", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "--exec=cmd")
      assert {:error, {:invalid_name, _}} = Coordinator.create(pid, "-flag")

      GenServer.stop(pid)
    end

    test "rejects target_branch starting with dash", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)
      {:ok, _} = Coordinator.create(pid, "agent-1")

      assert {:error, {:invalid_ref, _}} = Coordinator.merge(pid, "agent-1", "--upload-pack=cmd")
      assert {:error, {:invalid_ref, _}} = Coordinator.merge(pid, "agent-1", "-flag")

      GenServer.stop(pid)
    end

    test "rejects base_branch starting with dash", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:invalid_ref, _}} =
               Coordinator.create(pid, "agent-1", base_branch: "--upload-pack=cmd")

      GenServer.stop(pid)
    end

    test "rejects refs with dangerous characters", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:error, {:invalid_ref, _}} =
               Coordinator.merge(pid, "agent-1", "branch..lock")

      assert {:error, {:invalid_ref, _}} =
               Coordinator.create(pid, "agent-1", base_branch: "ref~1")

      GenServer.stop(pid)
    end

    test "accepts valid names and refs", %{repo: repo} do
      {:ok, pid} = Coordinator.start_link(repo_root: repo)

      assert {:ok, _} = Coordinator.create(pid, "agent-1")
      assert {:ok, _} = Coordinator.create(pid, "task_abc.123")
      assert {:ok, _} = Coordinator.create(pid, "My-Agent-2")

      GenServer.stop(pid)
    end
  end

  # -- Plugin interface tests --

  describe "manifest/0" do
    test "returns valid manifest" do
      manifest = GitWorktree.manifest()
      assert manifest.name == "worktree"
      assert manifest.version == "1.0.0"
      assert is_list(manifest.config_schema)
    end
  end

  describe "init/1" do
    test "returns stateful result with tools and child_spec", %{repo: repo} do
      assert {:stateful, tools, child_spec} = GitWorktree.init(%{"repo_root" => repo})

      assert length(tools) == 5

      names = Enum.map(tools, & &1.name)
      assert "create_worktree" in names
      assert "list_worktrees" in names
      assert "worktree_status" in names
      assert "merge_worktree" in names
      assert "delete_worktree" in names

      assert %{id: Coordinator, start: {Coordinator, :start_link, [_opts]}} = child_spec
    end

    test "raises for non-git directory" do
      tmp = Path.join(System.tmp_dir!(), "not_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert_raise ArgumentError, ~r/not a git repository/, fn ->
        GitWorktree.init(%{"repo_root" => tmp})
      end
    end

    test "write tools have :write kind", %{repo: repo} do
      {:stateful, tools, _} = GitWorktree.init(%{"repo_root" => repo})

      create = Enum.find(tools, &(&1.name == "create_worktree"))
      merge = Enum.find(tools, &(&1.name == "merge_worktree"))
      delete = Enum.find(tools, &(&1.name == "delete_worktree"))

      assert create.kind == :write
      assert merge.kind == :write
      assert delete.kind == :write
    end

    test "read tools have :read kind", %{repo: repo} do
      {:stateful, tools, _} = GitWorktree.init(%{"repo_root" => repo})

      list = Enum.find(tools, &(&1.name == "list_worktrees"))
      status = Enum.find(tools, &(&1.name == "worktree_status"))

      assert list.kind == :read
      assert status.kind == :read
    end
  end
end
