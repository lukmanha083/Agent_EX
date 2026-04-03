defmodule AgentEx.TaskList do
  @moduledoc """
  In-memory task list for orchestrator planning.

  Stores tasks per run_id in ETS. Tasks are ephemeral — they live for the
  duration of a conversation run and are used by the orchestrator to plan,
  track delegation, and reason about results.
  """

  @table :orchestrator_tasks

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  def create_task(run_id, task) do
    init()
    id = System.unique_integer([:positive])
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    entry = %{
      id: id,
      title: task[:title] || task["title"],
      status: :pending,
      agent: nil,
      result: nil,
      created_at: now,
      updated_at: now
    }

    tasks = get_tasks(run_id)
    :ets.insert(@table, {run_id, tasks ++ [entry]})
    entry
  end

  def update_task(run_id, task_id, updates) do
    tasks = get_tasks(run_id)

    case Enum.find_index(tasks, &(&1.id == task_id)) do
      nil ->
        {:error, :not_found}

      idx ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated =
          tasks
          |> Enum.at(idx)
          |> Map.merge(updates)
          |> Map.put(:updated_at, now)

        new_tasks = List.replace_at(tasks, idx, updated)
        :ets.insert(@table, {run_id, new_tasks})
        {:ok, updated}
    end
  end

  def get_tasks(run_id) do
    init()

    case :ets.lookup(@table, run_id) do
      [{^run_id, tasks}] -> tasks
      [] -> []
    end
  end

  def clear(run_id) do
    init()
    :ets.delete(@table, run_id)
    :ok
  end

  def format_tasks(run_id) do
    tasks = get_tasks(run_id)

    if tasks == [] do
      "No tasks created yet."
    else
      tasks
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {t, i} ->
        status_icon =
          case t.status do
            :pending -> "[ ]"
            :in_progress -> "[~]"
            :completed -> "[x]"
            :failed -> "[!]"
          end

        agent_info = if t.agent, do: " (#{t.agent})", else: ""
        result_info = if t.result, do: "\n   Result: #{t.result}", else: ""
        "#{i}. #{status_icon} #{t.title}#{agent_info}#{result_info}"
      end)
    end
  end
end
