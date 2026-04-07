defmodule AgentEx.Orchestrator do
  @moduledoc """
  GenStage producer that orchestrates multi-agent task execution.

  The orchestrator maintains a priority task queue, dispatches tasks to
  specialist consumers on demand, and re-evaluates the plan after each
  result using the LLM Planner. Budget awareness drives strategy shifts
  from exploration to convergence.

  ## Lifecycle

      {:ok, orch} = Orchestrator.start_link(model_client: client, specialists: specs)
      {:ok, result, summary} = Orchestrator.run(orch, "Analyze AAPL stock")
      Orchestrator.stop(orch)
  """

  use GenStage

  alias AgentEx.Orchestrator.{BudgetTracker, Planner, TaskQueue}

  require Logger

  defstruct [
    :goal,
    :model_client,
    :run_id,
    :caller,
    queue: TaskQueue.new(),
    budget: nil,
    completed: [],
    completed_ids: MapSet.new(),
    active: %{},
    iteration: 0,
    max_iterations: 30,
    max_concurrency: 3,
    specialists: %{},
    status: :idle,
    buffered_demand: 0,
    opts: []
  ]

  # --- Public API ---

  @doc "Start an orchestrator GenStage producer."
  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @doc """
  Run the orchestrator with a goal. Blocks until convergence or budget exhaustion.

  Returns `{:ok, result, summary}` or `{:error, reason}`.
  """
  def run(orchestrator, goal, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    GenStage.call(orchestrator, {:run, goal, opts}, timeout)
  end

  @doc "Report a specialist result back to the orchestrator."
  def report_result(orchestrator, task_id, result, usage) do
    GenStage.cast(orchestrator, {:result, task_id, result, usage})
  end

  @doc "Stop the orchestrator."
  def stop(orchestrator) do
    GenStage.stop(orchestrator, :normal)
  end

  # --- GenStage callbacks ---

  @impl true
  def init(opts) do
    model_client = Keyword.fetch!(opts, :model_client)
    specialists = Keyword.get(opts, :specialists, %{})
    max_concurrency = Keyword.get(opts, :max_concurrency, 3)
    budget_total = Keyword.get(opts, :budget)

    budget = if budget_total, do: BudgetTracker.new(budget_total), else: nil

    state = %__MODULE__{
      model_client: model_client,
      specialists: specialists,
      max_concurrency: max_concurrency,
      budget: budget,
      opts: opts
    }

    {:producer, state}
  end

  @impl true
  def handle_call({:run, goal, opts}, from, state) do
    run_id = Keyword.get(opts, :run_id, generate_run_id())
    specialist_list = Map.values(state.specialists)

    budget_prompt = if state.budget, do: BudgetTracker.to_prompt(state.budget), else: ""
    model_fn = Keyword.get(opts, :model_fn)
    plan_opts = [budget_prompt: budget_prompt, model_fn: model_fn]

    case Planner.initial_plan(goal, specialist_list, state.model_client, plan_opts) do
      {:ok, tasks} ->
        queue = TaskQueue.push_many(state.queue, tasks)

        Logger.info(
          "Orchestrator [#{run_id}]: planned #{length(tasks)} tasks for goal: #{truncate(goal, 80)}"
        )

        state = %{
          state
          | goal: goal,
            run_id: run_id,
            caller: from,
            queue: queue,
            status: :dispatching,
            opts: opts
        }

        {events, state} = dispatch_ready(state)
        {:noreply, events, state}

      {:error, reason} ->
        {:reply, {:error, reason}, [], state}
    end
  end

  @impl true
  def handle_demand(demand, state) do
    state = %{state | buffered_demand: state.buffered_demand + demand}
    {events, state} = dispatch_ready(state)
    {:noreply, events, state}
  end

  @impl true
  def handle_cast({:result, task_id, result, usage}, state) do
    Logger.info("Orchestrator [#{state.run_id}]: task #{task_id} completed")

    state = %{
      state
      | completed: [{task_id, result} | state.completed],
        completed_ids: MapSet.put(state.completed_ids, task_id),
        active: Map.delete(state.active, task_id),
        iteration: state.iteration + 1,
        budget:
          if(state.budget && usage,
            do: BudgetTracker.record(state.budget, usage),
            else: state.budget
          )
    }

    cond do
      state.iteration >= state.max_iterations ->
        do_converge(state)

      state.budget && BudgetTracker.zone(state.budget) == :report ->
        do_converge(state)

      true ->
        re_evaluate(state)
    end
  end

  @impl true
  def handle_info({:specialist_done, task_id, result, usage}, state) do
    handle_cast({:result, task_id, result, usage}, state)
  end

  # --- Internal ---

  defp dispatch_ready(%{buffered_demand: 0} = state), do: {[], state}
  defp dispatch_ready(%{status: status} = state) when status != :dispatching, do: {[], state}

  defp dispatch_ready(state) do
    max_to_take = max_dispatchable(state)

    if max_to_take > 0 do
      do_dispatch(state, max_to_take)
    else
      {[], state}
    end
  end

  defp max_dispatchable(%{budget: nil, buffered_demand: demand}), do: demand

  defp max_dispatchable(%{budget: budget, buffered_demand: demand, max_concurrency: base}) do
    min(demand, BudgetTracker.max_concurrency_for_zone(budget, base))
  end

  defp do_dispatch(state, max_to_take) do
    {tasks, queue} = TaskQueue.take(state.queue, max_to_take, state.completed_ids)

    active =
      Enum.reduce(tasks, state.active, fn task, acc ->
        Map.put(acc, task.id, :dispatched)
      end)

    state = %{
      state
      | queue: queue,
        active: active,
        buffered_demand: state.buffered_demand - length(tasks)
    }

    {tasks, state}
  end

  defp re_evaluate(state) do
    model_fn = Keyword.get(state.opts, :model_fn)
    budget_prompt = if state.budget, do: BudgetTracker.to_prompt(state.budget), else: ""
    plan_opts = [budget_prompt: budget_prompt, model_fn: model_fn]

    plan_state = %{
      goal: state.goal,
      completed: state.completed,
      queue: state.queue
    }

    case Planner.plan(plan_state, state.model_client, plan_opts) do
      {:ok, actions} ->
        state = apply_actions(actions, state)

        if state.status == :converging do
          do_converge(state)
        else
          {events, state} = dispatch_ready(state)
          {:noreply, events, state}
        end

      {:error, reason} ->
        Logger.warning("Orchestrator [#{state.run_id}]: re-evaluation failed: #{inspect(reason)}")
        {events, state} = dispatch_ready(state)
        {:noreply, events, state}
    end
  end

  defp apply_actions(actions, state) do
    Enum.reduce(actions, state, fn
      {:add, tasks}, s ->
        %{s | queue: TaskQueue.push_many(s.queue, tasks)}

      {:drop, ids}, s ->
        %{s | queue: TaskQueue.drop_many(s.queue, ids)}

      {:reorder, changes}, s ->
        queue =
          Enum.reduce(changes, s.queue, fn {id, priority}, q ->
            TaskQueue.reorder(q, id, priority)
          end)

        %{s | queue: queue}

      :converge, s ->
        %{s | status: :converging}

      {:refine, _summary}, s ->
        %{s | status: :converging}
    end)
  end

  defp do_converge(state) do
    model_fn = Keyword.get(state.opts, :model_fn)

    result =
      Planner.converge(state.completed, state.goal, state.model_client, model_fn: model_fn)

    summary = %{
      tasks_completed: length(state.completed),
      tasks_pending: TaskQueue.pending_count(state.queue),
      iterations: state.iteration,
      budget_used: if(state.budget, do: state.budget.used, else: 0),
      budget_total: if(state.budget, do: state.budget.total, else: 0)
    }

    reply =
      case result do
        {:ok, final_text} -> {:ok, final_text, summary}
        {:error, reason} -> {:error, reason}
      end

    if state.caller, do: GenStage.reply(state.caller, reply)

    state = %{state | status: :done, caller: nil}
    {:noreply, [], state}
  end

  defp truncate(text, max) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end

  defp generate_run_id do
    "orch-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
  end
end
