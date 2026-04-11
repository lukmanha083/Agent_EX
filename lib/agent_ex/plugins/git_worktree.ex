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

    coordinator_opts = [
      repo_root: repo_root,
      worktrees_dir: Map.get(config, "worktrees_dir"),
      base_branch: Map.get(config, "base_branch"),
      auto_cleanup: Map.get(config, "auto_cleanup", true)
    ] |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    tools = [
      create_worktree_tool(),
      list_worktrees_tool(),
      worktree_status_tool(),
      merge_worktree_tool(),
      delete_worktree_tool()
    ]

    child_spec = %{
      id: Coordinator,
      start: {Coordinator, :start_link, [coordinator_opts]},
      restart: :permanent
    }

    {:stateful, tools, child_spec}
  end

  @impl true
  def cleanup(coordinator_pid) do
    if Process.alive?(coordinator_pid) do
      GenServer.stop(coordinator_pid, :normal, 15_000)
    end

    :ok
  end

  # -- Tool definitions --

  defp create_worktree_tool do
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
        name = Map.fetch!(args, "name")

        opts =
          []
          |> maybe_put(:agent_id, Map.get(args, "agent_id"))
          |> maybe_put(:base_branch, Map.get(args, "base_branch"))

        case find_coordinator() do
          {:ok, pid} ->
            case Coordinator.create(pid, name, opts) do
              {:ok, info} ->
                {:ok, Jason.encode!(%{
                  name: info.name,
                  path: info.path,
                  branch: info.branch,
                  agent_id: info.agent_id
                }, pretty: true)}

              {:error, reason} ->
                {:error, format_error(reason)}
            end

          {:error, reason} ->
            {:error, format_error(reason)}
        end
      end
    )
  end

  defp list_worktrees_tool do
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
        case find_coordinator() do
          {:ok, pid} ->
            worktrees = Coordinator.list(pid)

            entries =
              Enum.map(worktrees, fn info ->
                %{
                  name: info.name,
                  path: info.path,
                  branch: info.branch,
                  agent_id: info.agent_id,
                  locked: info.locked
                }
              end)

            {:ok, Jason.encode!(entries, pretty: true)}

          {:error, reason} ->
            {:error, format_error(reason)}
        end
      end
    )
  end

  defp worktree_status_tool do
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
        case find_coordinator() do
          {:ok, pid} ->
            case Coordinator.status(pid, name) do
              {:ok, status} -> {:ok, Jason.encode!(status, pretty: true)}
              {:error, reason} -> {:error, format_error(reason)}
            end

          {:error, reason} ->
            {:error, format_error(reason)}
        end
      end
    )
  end

  defp merge_worktree_tool do
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
        case find_coordinator() do
          {:ok, pid} ->
            case Coordinator.merge(pid, name, target) do
              :ok -> {:ok, "Successfully merged worktree '#{name}' into '#{target}'"}
              {:error, reason} -> {:error, format_error(reason)}
            end

          {:error, reason} ->
            {:error, format_error(reason)}
        end
      end
    )
  end

  defp delete_worktree_tool do
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
        name = Map.fetch!(args, "name")
        force = Map.get(args, "force", false)
        delete_branch = Map.get(args, "delete_branch", true)

        case find_coordinator() do
          {:ok, pid} ->
            case Coordinator.delete(pid, name, force: force, delete_branch: delete_branch) do
              :ok -> {:ok, "Worktree '#{name}' deleted"}
              {:error, reason} -> {:error, format_error(reason)}
            end

          {:error, reason} ->
            {:error, format_error(reason)}
        end
      end
    )
  end

  # -- Helpers --

  defp find_coordinator do
    # Find the coordinator started by PluginSupervisor.
    # When started via PluginRegistry, the child_spec has id: Coordinator.
    children = DynamicSupervisor.which_children(AgentEx.PluginSupervisor)

    case Enum.find(children, fn {_id, pid, _type, [mod]} -> mod == Coordinator and is_pid(pid) end) do
      {_id, pid, _type, _mods} -> {:ok, pid}
      nil -> {:error, :coordinator_not_running}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]

  defp format_error({:already_exists, name}), do: "Worktree '#{name}' already exists"
  defp format_error({:not_found, name}), do: "Worktree '#{name}' not found"
  defp format_error({:worktree_add_failed, output}), do: "Failed to create worktree: #{output}"
  defp format_error({:worktree_remove_failed, output}), do: "Failed to remove worktree: #{output}"
  defp format_error({:conflict, files}), do: "Merge conflict in: #{Enum.join(files, ", ")}"
  defp format_error(:coordinator_not_running), do: "GitWorktree coordinator is not running"
  defp format_error(other), do: inspect(other)
end
