defmodule AgentEx.Orchestrator.TaskQueue do
  @moduledoc """
  Priority queue with dependency tracking for orchestrator task scheduling.

  Tasks have priorities (:high > :normal > :low) and optional `depends_on`
  lists — a task is only ready when all its dependencies have completed.
  The orchestrator takes ready tasks in priority order.
  """

  defstruct items: [], counter: 0

  @type priority :: :high | :normal | :low
  @type task :: %{
          id: String.t(),
          specialist: String.t(),
          input: String.t(),
          priority: priority(),
          depends_on: [String.t()],
          metadata: map()
        }
  @type t :: %__MODULE__{items: [task()], counter: non_neg_integer()}

  @priority_weight %{high: 0, normal: 1, low: 2}

  @doc "Create an empty task queue."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Push a task onto the queue. Assigns defaults for missing fields."
  @spec push(t(), map()) :: t()
  def push(%__MODULE__{} = q, task) when is_map(task) do
    task =
      task
      |> Map.put_new(:priority, :normal)
      |> Map.put_new(:depends_on, [])
      |> Map.put_new(:metadata, %{})

    %{q | items: [task | q.items], counter: q.counter + 1}
  end

  @doc "Push multiple tasks at once."
  @spec push_many(t(), [map()]) :: t()
  def push_many(%__MODULE__{} = q, tasks) when is_list(tasks) do
    Enum.reduce(tasks, q, &push(&2, &1))
  end

  @doc """
  Take up to `n` ready tasks in priority order.

  A task is ready when all its `depends_on` IDs are in `completed_ids`.
  Returns `{taken_tasks, remaining_queue}`.
  """
  @spec take(t(), pos_integer()) :: {[task()], t()}
  @spec take(t(), pos_integer(), MapSet.t()) :: {[task()], t()}
  def take(%__MODULE__{} = q, n, completed_ids \\ MapSet.new()) when n > 0 do
    {ready, blocked} = Enum.split_with(q.items, &task_ready?(&1, completed_ids))

    sorted = Enum.sort_by(ready, &Map.get(@priority_weight, &1.priority, 1))
    {taken, remaining_ready} = Enum.split(sorted, n)

    %{q | items: remaining_ready ++ blocked}
    |> then(&{taken, &1})
  end

  @doc "Drop a task by ID."
  @spec drop(t(), String.t()) :: t()
  def drop(%__MODULE__{} = q, task_id) do
    %{q | items: Enum.reject(q.items, &(&1.id == task_id))}
  end

  @doc "Drop multiple tasks by ID."
  @spec drop_many(t(), [String.t()]) :: t()
  def drop_many(%__MODULE__{} = q, task_ids) do
    id_set = MapSet.new(task_ids)
    %{q | items: Enum.reject(q.items, &MapSet.member?(id_set, &1.id))}
  end

  @doc "Change a task's priority."
  @spec reorder(t(), String.t(), priority()) :: t()
  def reorder(%__MODULE__{} = q, task_id, new_priority) do
    items =
      Enum.map(q.items, fn task ->
        if task.id == task_id, do: %{task | priority: new_priority}, else: task
      end)

    %{q | items: items}
  end

  @doc "Number of pending tasks."
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(%__MODULE__{items: items}), do: length(items)

  @doc "Check if any tasks are ready given completed dependencies."
  @spec has_ready_tasks?(t(), MapSet.t()) :: boolean()
  def has_ready_tasks?(%__MODULE__{items: items}, completed_ids) do
    Enum.any?(items, &task_ready?(&1, completed_ids))
  end

  @doc "List all task IDs in the queue."
  @spec task_ids(t()) :: [String.t()]
  def task_ids(%__MODULE__{items: items}), do: Enum.map(items, & &1.id)

  defp task_ready?(%{depends_on: []}, _completed_ids), do: true

  defp task_ready?(%{depends_on: deps}, completed_ids) do
    Enum.all?(deps, &MapSet.member?(completed_ids, &1))
  end
end
