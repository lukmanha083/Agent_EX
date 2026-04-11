defmodule AgentEx.Plugins.GitWorktree do
  @moduledoc """
  Built-in plugin for git worktree management enabling parallel agent execution.

  Each agent gets its own worktree (isolated working directory + branch) while
  sharing the same git object store. This allows multiple agents to work on the
  same codebase concurrently without file collisions or index conflicts.

  ## Architecture

      Main Repo (.git/objects shared)
        ├── .worktrees/agent-a/  →  branch worktree/agent-a
        ├── .worktrees/agent-b/  →  branch worktree/agent-b
        └── .worktrees/agent-c/  →  branch worktree/agent-c

  ## Config

  - `"repo_root"` — root directory of the git repository (required)
  - `"worktrees_dir"` — directory for worktrees (optional, default: `<repo>/.worktrees`)
  - `"base_branch"` — default base branch (optional, auto-detected from origin/HEAD)
  - `"auto_cleanup"` — clean up worktrees on plugin detach (optional, default: true)

  ## Tools provided

  - `create_worktree` — create an isolated worktree with its own branch
  - `list_worktrees` — list all active worktrees
  - `worktree_status` — check uncommitted changes and branch state
  - `merge_worktree` — merge a worktree's branch into a target (serialized)
  - `delete_worktree` — remove a worktree and optionally its branch
  """

  @behaviour AgentEx.ToolPlugin

  alias AgentEx.Tool
  alias AgentEx.Plugins.GitWorktree.Coordinator

  @impl true
  def manifest do
    %{
      name: "worktree",
      version: "1.0.0",
      description: "Git worktree management for parallel agent execution",
      config_schema: [
        {:repo_root, :string, "Root directory of the git repository"},
        {:worktrees_dir, :string, "Directory for worktrees", optional: true},
        {:base_branch, :string, "Default base branch", optional: true},
        {:auto_cleanup, :boolean, "Clean up worktrees on detach", optional: true}
      ]
    }
  end

  @impl true
  def init(config) do
    repo_root = Map.fetch!(config, "repo_root") |> Path.expand()

    unless File.dir?(Path.join(repo_root, ".git")) or File.regular?(Path.join(repo_root, ".git")) do
      raise ArgumentError, "repo_root #{repo_root} is not a git repository"
    end

    coordinator_opts =
      [
        repo_root: repo_root,
        worktrees_dir: Map.get(config, "worktrees_dir"),
        base_branch: Map.get(config, "base_branch"),
        auto_cleanup: Map.get(config, "auto_cleanup", true)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    # Start coordinator eagerly so tool closures can capture the pid.
    # PluginRegistry will re-parent it under PluginSupervisor via child_spec.
    {:ok, coordinator} = Coordinator.start_link(coordinator_opts)

    tools = [
      create_worktree_tool(coordinator),
      list_worktrees_tool(coordinator),
      worktree_status_tool(coordinator),
      merge_worktree_tool(coordinator),
      delete_worktree_tool(coordinator)
    ]

    child_spec = %{
      id: Coordinator,
      start: {Coordinator, :start_link, [coordinator_opts]},
      restart: :permanent
    }

    # Stop the eagerly-started coordinator — PluginRegistry will start a new
    # one via child_spec. The tool closures hold the pid, which will be
    # replaced when PluginRegistry starts the supervised instance.
    # NOTE: When used standalone (not via PluginRegistry), the caller should
    # start the coordinator themselves and pass tools directly.
    GenServer.stop(coordinator, :normal)

    {:stateful, tools, child_spec}
  end

  @impl true
  def cleanup(coordinator_pid) do
    if is_pid(coordinator_pid) and Process.alive?(coordinator_pid) do
      GenServer.stop(coordinator_pid, :normal, 15_000)
    end

    :ok
  end

  # -- Tool definitions --
  # Each tool receives the coordinator module for Process.whereis lookup.
  # When started via PluginSupervisor, the coordinator is findable by scanning
  # supervisor children. We use a simple helper to locate it.

  defp create_worktree_tool(_coordinator) do
    Tool.new(
      name: "create_worktree",
      description:
        "Create a new git worktree with an isolated branch for parallel development. " <>
          "Returns the worktree path and branch name. Each worktree has its own " <>
          "working directory and index, sharing the git object store.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Unique name for the worktree (used as directory name and branch suffix)"
          },
          "agent_id" => %{
            "type" => "string",
            "description" => "Agent ID to associate with this worktree (optional, defaults to name)"
          },
          "base_branch" => %{
            "type" => "string",
            "description" => "Branch to base the worktree on (optional, uses configured default)"
          }
        },
        "required" => ["name"]
      },
      kind: :write,
      function: fn args ->
        with {:ok, pid} <- find_coordinator() do
          name = Map.fetch!(args, "name")
          opts = build_opts(args, [:agent_id, :base_branch])

          case Coordinator.create(pid, name, opts) do
            {:ok, info} ->
              {:ok,
               Jason.encode!(
                 %{name: info.name, path: info.path, branch: info.branch, agent_id: info.agent_id},
                 pretty: true
               )}

            {:error, reason} ->
              {:error, format_error(reason)}
          end
        end
      end
    )
  end

  defp list_worktrees_tool(_coordinator) do
    Tool.new(
      name: "list_worktrees",
      description: "List all active git worktrees with their paths, branches, and agent assignments.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      kind: :read,
      function: fn _args ->
        with {:ok, pid} <- find_coordinator() do
          entries =
            Coordinator.list(pid)
            |> Enum.map(fn info ->
              %{name: info.name, path: info.path, branch: info.branch, agent_id: info.agent_id}
            end)

          {:ok, Jason.encode!(entries, pretty: true)}
        end
      end
    )
  end

  defp worktree_status_tool(_coordinator) do
    Tool.new(
      name: "worktree_status",
      description:
        "Get the status of a worktree: uncommitted changes, branch info, " <>
          "and whether there are unpushed commits.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Name of the worktree to check"
          }
        },
        "required" => ["name"]
      },
      kind: :read,
      function: fn %{"name" => name} ->
        with {:ok, pid} <- find_coordinator() do
          case Coordinator.status(pid, name) do
            {:ok, status} -> {:ok, Jason.encode!(status, pretty: true)}
            {:error, reason} -> {:error, format_error(reason)}
          end
        end
      end
    )
  end

  defp merge_worktree_tool(_coordinator) do
    Tool.new(
      name: "merge_worktree",
      description:
        "Merge a worktree's branch into a target branch. Merges are serialized " <>
          "(one at a time) to prevent race conditions. Returns conflict details on failure.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Name of the worktree whose branch to merge"
          },
          "target_branch" => %{
            "type" => "string",
            "description" => "Target branch to merge into (e.g. 'main', 'develop')"
          }
        },
        "required" => ["name", "target_branch"]
      },
      kind: :write,
      function: fn %{"name" => name, "target_branch" => target} ->
        with {:ok, pid} <- find_coordinator() do
          case Coordinator.merge(pid, name, target) do
            :ok -> {:ok, "Successfully merged worktree '#{name}' into '#{target}'"}
            {:error, reason} -> {:error, format_error(reason)}
          end
        end
      end
    )
  end

  defp delete_worktree_tool(_coordinator) do
    Tool.new(
      name: "delete_worktree",
      description:
        "Delete a worktree and its branch. Use force=true to remove even with uncommitted changes.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Name of the worktree to delete"
          },
          "force" => %{
            "type" => "boolean",
            "description" => "Force delete even with uncommitted changes (default: false)"
          },
          "delete_branch" => %{
            "type" => "boolean",
            "description" => "Also delete the worktree branch (default: true)"
          }
        },
        "required" => ["name"]
      },
      kind: :write,
      function: fn args ->
        with {:ok, pid} <- find_coordinator() do
          name = Map.fetch!(args, "name")
          force = Map.get(args, "force", false)
          delete_branch = Map.get(args, "delete_branch", true)

          case Coordinator.delete(pid, name, force: force, delete_branch: delete_branch) do
            :ok -> {:ok, "Worktree '#{name}' deleted"}
            {:error, reason} -> {:error, format_error(reason)}
          end
        end
      end
    )
  end

  # -- Helpers --

  # Locate the coordinator via PluginSupervisor. Returns {:error, _} for
  # `with` short-circuit so tool functions don't need nested cases.
  defp find_coordinator do
    children = DynamicSupervisor.which_children(AgentEx.PluginSupervisor)

    case Enum.find(children, fn {_id, pid, _type, mods} ->
           is_pid(pid) and Coordinator in List.wrap(mods)
         end) do
      {_id, pid, _type, _mods} -> {:ok, pid}
      nil -> {:error, "GitWorktree coordinator is not running"}
    end
  end

  defp build_opts(args, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case Map.get(args, Atom.to_string(key)) do
        nil -> acc
        val -> [{key, val} | acc]
      end
    end)
  end

  defp format_error({:already_exists, name}), do: "Worktree '#{name}' already exists"
  defp format_error({:not_found, name}), do: "Worktree '#{name}' not found"
  defp format_error({:worktree_add_failed, output}), do: "Failed to create worktree: #{output}"
  defp format_error({:worktree_remove_failed, output}), do: "Failed to remove worktree: #{output}"
  defp format_error({:conflict, files}), do: "Merge conflict in: #{Enum.join(files, ", ")}"
  defp format_error(other), do: inspect(other)
end
