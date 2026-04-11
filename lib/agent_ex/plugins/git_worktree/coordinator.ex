defmodule AgentEx.Plugins.GitWorktree.Coordinator do
  @moduledoc """
  GenServer that manages git worktree lifecycle for parallel agent execution.

  Tracks active worktrees, serializes merge operations to prevent conflicts,
  and handles cleanup on termination. Each worktree gets its own branch and
  isolated working directory sharing the same git object store.

  ## Architecture

      Main Repository (.git/objects shared)
        ├── worktree-agent-1/  → branch agent-1/task-abc
        ├── worktree-agent-2/  → branch agent-2/task-abc
        └── worktree-agent-3/  → branch agent-3/task-abc

  Concurrent commits on different branches are safe — Git uses per-worktree
  index files and file-based ref locking. Merges are serialized through
  `GenServer.call` to prevent race conditions on the target branch.
  """

  use GenServer

  require Logger

  defmodule WorktreeInfo do
    @moduledoc "Metadata for an active worktree."
    @enforce_keys [:name, :path, :branch]
    defstruct [:name, :path, :branch, :agent_id, created_at: nil, locked: false]

    @type t :: %__MODULE__{
            name: String.t(),
            path: String.t(),
            branch: String.t(),
            agent_id: String.t() | nil,
            created_at: DateTime.t() | nil,
            locked: boolean()
          }
  end

  defstruct [:repo_root, :worktrees_dir, :base_branch, worktrees: %{}, auto_cleanup: true]

  @type t :: %__MODULE__{
          repo_root: String.t(),
          worktrees_dir: String.t(),
          base_branch: String.t() | nil,
          worktrees: %{String.t() => WorktreeInfo.t()},
          auto_cleanup: boolean()
        }

  # -- Public API --

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Create a new worktree for an agent. Returns `{:ok, info}` or `{:error, reason}`."
  @spec create(GenServer.server(), String.t(), keyword()) ::
          {:ok, WorktreeInfo.t()} | {:error, term()}
  def create(server, name, opts \\ []) do
    GenServer.call(server, {:create, name, opts}, 30_000)
  end

  @doc "List all active worktrees."
  @spec list(GenServer.server()) :: [WorktreeInfo.t()]
  def list(server) do
    GenServer.call(server, :list)
  end

  @doc "Get status of a worktree (uncommitted changes, commits ahead, branch)."
  @spec status(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(server, name) do
    GenServer.call(server, {:status, name}, 15_000)
  end

  @doc """
  Merge a worktree's branch into a target branch. Serialized to prevent conflicts.
  Returns `:ok` or `{:error, {:conflict, files}}`.
  """
  @spec merge(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def merge(server, name, target_branch) do
    GenServer.call(server, {:merge, name, target_branch}, 60_000)
  end

  @doc "Delete a worktree and optionally its branch."
  @spec delete(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(server, name, opts \\ []) do
    GenServer.call(server, {:delete, name, opts}, 15_000)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    repo_root = Keyword.fetch!(opts, :repo_root) |> Path.expand()
    worktrees_dir = Keyword.get(opts, :worktrees_dir, Path.join(repo_root, ".worktrees"))
    base_branch = Keyword.get(opts, :base_branch)
    auto_cleanup = Keyword.get(opts, :auto_cleanup, true)

    File.mkdir_p!(worktrees_dir)
    ensure_gitignored(repo_root, worktrees_dir)

    base_branch = base_branch || detect_base_branch(repo_root)

    state = %__MODULE__{
      repo_root: repo_root,
      worktrees_dir: worktrees_dir,
      base_branch: base_branch,
      auto_cleanup: auto_cleanup
    }

    Logger.info(
      "GitWorktree.Coordinator started: repo=#{repo_root} base=#{base_branch} dir=#{worktrees_dir}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:create, name, opts}, _from, state) do
    if Map.has_key?(state.worktrees, name) do
      {:reply, {:error, {:already_exists, name}}, state}
    else
      agent_id = Keyword.get(opts, :agent_id, name)
      base = Keyword.get(opts, :base_branch, state.base_branch)
      branch = "worktree/#{name}"
      path = Path.join(state.worktrees_dir, name)

      case git_worktree_add(state.repo_root, path, branch, base) do
        :ok ->
          info = %WorktreeInfo{
            name: name,
            path: path,
            branch: branch,
            agent_id: agent_id,
            created_at: DateTime.utc_now()
          }

          Logger.info("GitWorktree: created '#{name}' at #{path} on branch #{branch}")
          {:reply, {:ok, info}, %{state | worktrees: Map.put(state.worktrees, name, info)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.worktrees), state}
  end

  def handle_call({:status, name}, _from, state) do
    case Map.fetch(state.worktrees, name) do
      {:ok, info} ->
        {:reply, git_worktree_status(info.path, info.branch), state}

      :error ->
        {:reply, {:error, {:not_found, name}}, state}
    end
  end

  def handle_call({:merge, name, target_branch}, _from, state) do
    case Map.fetch(state.worktrees, name) do
      {:ok, info} ->
        result = git_merge_branch(state.repo_root, info.branch, target_branch)
        {:reply, result, state}

      :error ->
        {:reply, {:error, {:not_found, name}}, state}
    end
  end

  def handle_call({:delete, name, opts}, _from, state) do
    force = Keyword.get(opts, :force, false)
    delete_branch = Keyword.get(opts, :delete_branch, true)

    case Map.fetch(state.worktrees, name) do
      {:ok, info} ->
        case git_worktree_remove(state.repo_root, info.path, force) do
          :ok ->
            if delete_branch do
              git_delete_branch(state.repo_root, info.branch)
            end

            Logger.info("GitWorktree: deleted '#{name}'")
            {:reply, :ok, %{state | worktrees: Map.delete(state.worktrees, name)}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, {:not_found, name}}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.auto_cleanup do
      Logger.info("GitWorktree.Coordinator: cleaning up #{map_size(state.worktrees)} worktrees")

      Enum.each(state.worktrees, fn {name, info} ->
        case git_worktree_remove(state.repo_root, info.path, true) do
          :ok ->
            git_delete_branch(state.repo_root, info.branch)
            Logger.debug("GitWorktree: cleaned up '#{name}'")

          {:error, reason} ->
            Logger.warning("GitWorktree: failed to clean up '#{name}': #{inspect(reason)}")
        end
      end)

      git_worktree_prune(state.repo_root)
    end

    :ok
  end

  # -- Git operations --

  defp git_worktree_add(repo_root, path, branch, base) do
    case git(repo_root, ["worktree", "add", "-b", branch, path, base]) do
      {:ok, _output} -> :ok
      {:error, output} -> {:error, {:worktree_add_failed, output}}
    end
  end

  defp git_worktree_remove(repo_root, path, force) do
    args = ["worktree", "remove"] ++ if(force, do: ["--force"], else: []) ++ [path]

    case git(repo_root, args) do
      {:ok, _} -> :ok
      {:error, output} -> {:error, {:worktree_remove_failed, output}}
    end
  end

  defp git_worktree_prune(repo_root) do
    git(repo_root, ["worktree", "prune"])
  end

  defp git_worktree_status(worktree_path, branch) do
    with {:ok, status_output} <- git(worktree_path, ["status", "--porcelain"]),
         {:ok, log_output} <- git(worktree_path, ["log", "--oneline", "HEAD", "--not", "--remotes", "--no-walk"]) do
      uncommitted =
        status_output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok,
       %{
         branch: branch,
         path: worktree_path,
         uncommitted_changes: uncommitted,
         has_changes: uncommitted != [],
         unpushed: String.trim(log_output) != ""
       }}
    end
  end

  defp git_merge_branch(repo_root, source_branch, target_branch) do
    # Merge is done from the main repo root to avoid worktree branch conflicts.
    # We use --no-ff to preserve branch topology.
    with {:ok, _} <- git(repo_root, ["checkout", target_branch]) do
      case git(repo_root, ["merge", "--no-ff", source_branch, "-m", "merge: #{source_branch} into #{target_branch}"]) do
        {:ok, _output} ->
          :ok

        {:error, output} ->
          # Abort the failed merge and report conflicts
          git(repo_root, ["merge", "--abort"])

          conflict_files =
            output
            |> String.split("\n", trim: true)
            |> Enum.filter(&String.contains?(&1, "CONFLICT"))
            |> Enum.map(&String.trim/1)

          {:error, {:conflict, conflict_files}}
      end
    end
  end

  defp git_delete_branch(repo_root, branch) do
    case git(repo_root, ["branch", "-D", branch]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp detect_base_branch(repo_root) do
    case git(repo_root, ["symbolic-ref", "refs/remotes/origin/HEAD"]) do
      {:ok, ref} ->
        ref
        |> String.trim()
        |> String.replace("refs/remotes/origin/", "")

      {:error, _} ->
        case git(repo_root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
          {:ok, branch} -> String.trim(branch)
          {:error, _} -> "main"
        end
    end
  end

  # Ensure the worktrees directory is in .gitignore so `git add .` never
  # picks up the embedded worktree repos inside the sandbox.
  defp ensure_gitignored(repo_root, worktrees_dir) do
    relative = Path.relative_to(worktrees_dir, repo_root)

    # Only relevant when worktrees dir is inside the repo
    if relative != worktrees_dir do
      gitignore_path = Path.join(repo_root, ".gitignore")
      entry = "/#{relative}"

      existing =
        case File.read(gitignore_path) do
          {:ok, content} -> content
          {:error, _} -> ""
        end

      unless String.contains?(existing, entry) do
        # Append with a newline guard
        separator = if existing != "" and not String.ends_with?(existing, "\n"), do: "\n", else: ""
        File.write!(gitignore_path, existing <> separator <> entry <> "\n")
      end
    end
  end

  @doc false
  def git(cwd, args) do
    try do
      case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
