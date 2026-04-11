defmodule AgentEx.TaskList do
  @moduledoc """
  Deprecated: Use `AgentEx.TaskManager` instead.

  This module is retained for backward compatibility. All functions delegate
  to `AgentEx.TaskManager`. Will be removed in a future release.
  """

  require Logger

  @deprecated "Use AgentEx.TaskManager.create_task/2 instead"
  def create_task(run_id, task) do
    title = task[:title] || task["title"] || "Untitled"

    case AgentEx.TaskManager.create_task(run_id, %{title: title}) do
      {:ok, t} -> t
      {:error, _} -> %{id: 0, title: title}
    end
  end

  @deprecated "Use AgentEx.TaskManager.update_task/2 instead"
  def update_task(_run_id, task_id, updates) do
    string_updates =
      Enum.reduce(updates, %{}, fn
        {:status, v}, acc -> Map.put(acc, :status, to_string(v))
        {:result, v}, acc -> Map.put(acc, :result, v)
        {k, v}, acc -> Map.put(acc, k, v)
      end)

    AgentEx.TaskManager.update_task(task_id, string_updates)
  end

  @deprecated "Use AgentEx.TaskManager.list_tasks/1 instead"
  def get_tasks(run_id) do
    AgentEx.TaskManager.list_tasks(run_id)
  end

  @deprecated "Use AgentEx.TaskManager.clear_cache/1 instead"
  def clear(run_id) do
    AgentEx.TaskManager.clear_cache(run_id)
  end

  @deprecated "Use AgentEx.TaskManager.format_tasks/1 instead"
  def format_tasks(run_id) do
    AgentEx.TaskManager.format_tasks(run_id)
  end
end
