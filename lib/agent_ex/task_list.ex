defmodule AgentEx.TaskList do
  @moduledoc """
  In-memory task list for orchestrator planning.

  Stores tasks per run_id in ETS. Tasks are ephemeral — they live for the
  duration of a conversation run and are used by the orchestrator to plan,
  track delegation, and reason about results.

  The ETS table is owned by this GenServer to prevent ownership leaks
  and race conditions from lazy creation.
  """

  use GenServer

  @table :orchestrator_tasks

  # -- Client API --

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def create_task(run_id, task) do
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
    case :ets.lookup(@table, run_id) do
      [{^run_id, tasks}] -> tasks
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  def clear(run_id) do
    :ets.delete(@table, run_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def format_tasks(run_id) do
    tasks = get_tasks(run_id)

    if tasks == [] do
      "No tasks created yet."
    else
      tasks
      |> Enum.with_index(1)
      |> Enum.map_join("\n", &format_task_line/1)
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  # -- Private --

  defp format_task_line({t, i}) do
    icon = status_icon(t.status)
    agent_info = if t.agent, do: " (#{t.agent})", else: ""
    result_info = if t.result, do: "\n   Result: #{t.result}", else: ""
    "#{i}. #{icon} #{t.title}#{agent_info}#{result_info}"
  end

  defp status_icon(:pending), do: "[ ]"
  defp status_icon(:in_progress), do: "[~]"
  defp status_icon(:completed), do: "[x]"
  defp status_icon(:failed), do: "[!]"
end
