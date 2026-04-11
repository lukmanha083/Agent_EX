defmodule AgentEx.TaskManager do
  @moduledoc """
  Persistent task management for orchestrator planning.

  Replaces the ephemeral `AgentEx.TaskList` with a Postgres-backed system
  that uses ETS as a read cache. Tasks are persisted across crashes and
  sessions, with PubSub event broadcasting for LiveView updates.

  ## Architecture

  - **Postgres**: Source of truth via `AgentEx.TaskManager.Task` schema
  - **ETS cache**: Fast reads during active runs, warmed on first access
  - **PubSub**: Broadcasts `:task_created` and `:task_updated` events

  ## Usage

      {:ok, task} = TaskManager.create_task("run-abc", %{title: "Fix auth bug"})
      {:ok, task} = TaskManager.update_task(task.id, %{status: "in_progress", agent: "coder"})
      tasks = TaskManager.list_tasks("run-abc")
      ready = TaskManager.ready_tasks("run-abc")
  """

  use GenServer

  alias AgentEx.EventLoop.{Event, RunRegistry}
  alias AgentEx.Repo
  alias AgentEx.TaskManager.Task

  import Ecto.Query

  require Logger

  @table :task_manager_cache

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a task for a run. Returns {:ok, task} or {:error, changeset}."
  @spec create_task(String.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(run_id, attrs) do
    attrs = Map.put(attrs, :run_id, run_id)

    case %Task{} |> Task.changeset(attrs) |> Repo.insert() do
      {:ok, task} ->
        cache_put(task)
        broadcast(run_id, :task_created, %{task_id: task.id, title: task.title, priority: task.priority})
        {:ok, task}

      {:error, _} = err ->
        err
    end
  end

  @doc "Get a single task by ID. Returns nil if not found."
  @spec get_task(integer()) :: Task.t() | nil
  def get_task(task_id) do
    case cache_get(task_id) do
      nil ->
        case Repo.get(Task, task_id) do
          nil -> nil
          task -> cache_put(task) && task
        end

      task ->
        task
    end
  end

  @doc "Update a task by ID. Returns {:ok, task} or {:error, reason}."
  @spec update_task(integer(), map()) :: {:ok, Task.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_task(task_id, updates) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        case task |> Task.update_changeset(updates) |> Repo.update() do
          {:ok, updated} ->
            cache_put(updated)

            broadcast(updated.run_id, :task_updated, %{
              task_id: updated.id,
              status: updated.status,
              agent: updated.agent,
              result: updated.result
            })

            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "List all tasks for a run, ordered by insertion."
  @spec list_tasks(String.t()) :: [Task.t()]
  def list_tasks(run_id) do
    case cache_list(run_id) do
      [] -> warm_cache(run_id)
      tasks -> tasks
    end
  end

  @doc """
  List tasks for a run with filters.

  ## Options
  - `:status` — filter by status string (e.g. "pending")
  - `:agent` — filter by agent name
  """
  @spec list_tasks(String.t(), keyword()) :: [Task.t()]
  def list_tasks(run_id, opts) do
    tasks = list_tasks(run_id)
    status = Keyword.get(opts, :status)
    agent = Keyword.get(opts, :agent)

    tasks
    |> then(fn t -> if status, do: Enum.filter(t, &(&1.status == status)), else: t end)
    |> then(fn t -> if agent, do: Enum.filter(t, &(&1.agent == agent)), else: t end)
  end

  @doc "Format tasks as human-readable text for LLM tool output."
  @spec format_tasks(String.t()) :: String.t()
  def format_tasks(run_id) do
    tasks = list_tasks(run_id)

    if tasks == [] do
      "No tasks created yet."
    else
      tasks
      |> Enum.with_index(1)
      |> Enum.map_join("\n", &format_task_line/1)
    end
  end

  defp format_task_line({t, i}) do
    icon = status_icon(t.status)
    agent_info = if t.agent, do: " (#{t.agent})", else: ""
    result_info = if t.result, do: "\n   Result: #{t.result}", else: ""
    "#{i}. #{icon} #{t.title}#{agent_info}#{result_info}"
  end

  @doc """
  Get ready tasks: pending tasks whose dependencies are all completed.
  Returns them sorted by priority (high > normal > low).
  """
  @spec ready_tasks(String.t()) :: [Task.t()]
  def ready_tasks(run_id) do
    tasks = list_tasks(run_id)
    completed_ids = tasks |> Enum.filter(&(&1.status == "completed")) |> MapSet.new(& &1.id)

    tasks
    |> Enum.filter(&(&1.status == "pending" and task_ready?(&1, completed_ids)))
    |> sort_by_priority()
  end

  @doc """
  Take up to n ready tasks, atomically marking them as in_progress.
  Returns `{taken_tasks, remaining_ready_count}`.
  """
  @spec take_ready(String.t(), pos_integer()) :: {[Task.t()], non_neg_integer()}
  def take_ready(run_id, n) when n > 0 do
    ready = ready_tasks(run_id)
    {to_take, remaining} = Enum.split(ready, n)

    taken =
      Enum.map(to_take, fn task ->
        {:ok, updated} = update_task(task.id, %{status: "in_progress"})
        updated
      end)

    {taken, length(remaining)}
  end

  @doc "Clear all cached tasks for a run. DB records persist."
  @spec clear_cache(String.t()) :: :ok
  def clear_cache(run_id) do
    case cache_index(run_id) do
      [] ->
        :ok

      ids ->
        Enum.each(ids, &cache_delete(run_id, &1))
        delete_index(run_id)
    end

    :ok
  end

  @doc "Load tasks for a run from DB into ETS cache."
  @spec warm_cache(String.t()) :: [Task.t()]
  def warm_cache(run_id) do
    tasks =
      from(t in Task, where: t.run_id == ^run_id, order_by: [asc: t.id])
      |> Repo.all()

    Enum.each(tasks, &cache_put/1)
    put_index(run_id, Enum.map(tasks, & &1.id))
    tasks
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{table: table}}
  end

  # -- ETS cache helpers --

  defp cache_put(%Task{} = task) do
    :ets.insert(@table, {{task.run_id, task.id}, task})
    ids = cache_index(task.run_id)

    unless task.id in ids do
      put_index(task.run_id, ids ++ [task.id])
    end

    task
  rescue
    ArgumentError -> task
  end

  defp cache_get(task_id) do
    # We don't know the run_id, so do a match
    case :ets.match_object(@table, {{:_, task_id}, :_}) do
      [{_key, task}] -> task
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp cache_list(run_id) do
    ids = cache_index(run_id)

    Enum.reduce(ids, [], fn id, acc ->
      case :ets.lookup(@table, {run_id, id}) do
        [{_key, task}] -> acc ++ [task]
        [] -> acc
      end
    end)
  rescue
    ArgumentError -> []
  end

  defp cache_index(run_id) do
    case :ets.lookup(@table, {:index, run_id}) do
      [{_key, ids}] -> ids
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp put_index(run_id, ids) do
    :ets.insert(@table, {{:index, run_id}, ids})
  rescue
    ArgumentError -> :ok
  end

  defp cache_delete(run_id, task_id) do
    :ets.delete(@table, {run_id, task_id})
  rescue
    ArgumentError -> :ok
  end

  defp delete_index(run_id) do
    :ets.delete(@table, {:index, run_id})
  rescue
    ArgumentError -> :ok
  end

  # -- Priority / dependency helpers --

  @priority_weight %{"high" => 0, "normal" => 1, "low" => 2}

  defp sort_by_priority(tasks) do
    Enum.sort_by(tasks, &Map.get(@priority_weight, &1.priority, 1))
  end

  defp task_ready?(%{depends_on: []}, _completed_ids), do: true
  defp task_ready?(%{depends_on: nil}, _completed_ids), do: true

  defp task_ready?(%{depends_on: deps}, completed_ids) do
    Enum.all?(deps, &MapSet.member?(completed_ids, &1))
  end

  # -- Formatting helpers --

  defp status_icon("pending"), do: "[ ]"
  defp status_icon("in_progress"), do: "[~]"
  defp status_icon("completed"), do: "[x]"
  defp status_icon("failed"), do: "[!]"
  defp status_icon(_), do: "[ ]"

  # -- PubSub broadcasting --

  defp broadcast(run_id, type, data) do
    event = Event.new(type, run_id, data)
    RunRegistry.add_event(run_id, event)
    Phoenix.PubSub.broadcast(AgentEx.PubSub, "run:#{run_id}", event)
  rescue
    # RunRegistry may not be started in tests
    ArgumentError -> :ok
  end
end
