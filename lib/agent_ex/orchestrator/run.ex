defmodule AgentEx.Orchestrator.Run do
  @moduledoc """
  Ecto schema and persistence for orchestration runs.

  Each run tracks: goal, task decomposition, dependency graph, budget state,
  and results. Survives crashes and session changes — the Orchestrator can
  resume from a persisted run.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias AgentEx.Repo

  require Logger

  @primary_key {:id, :string, autogenerate: false}
  schema "orchestration_runs" do
    belongs_to(:project, AgentEx.Projects.Project)
    field(:user_id, :integer)
    field(:goal, :string)
    field(:status, :string, default: "running")
    field(:tasks, {:array, :map}, default: [])
    field(:dependency_graph, :map, default: %{})
    field(:budget_total, :integer)
    field(:budget_used, :integer, default: 0)
    field(:budget_velocity, :float, default: 0.0)
    field(:iteration, :integer, default: 0)
    field(:max_iterations, :integer, default: 30)
    field(:result, :string)
    field(:started_at, :utc_datetime_usec)
    field(:paused_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :id,
    :project_id,
    :user_id,
    :goal,
    :status,
    :tasks,
    :dependency_graph,
    :budget_total,
    :budget_used,
    :budget_velocity,
    :iteration,
    :max_iterations,
    :result,
    :started_at,
    :paused_at,
    :completed_at
  ]

  def changeset(run, attrs) do
    run
    |> cast(attrs, @fields)
    |> validate_required([:id, :goal])
    |> validate_inclusion(:status, ~w(running paused completed failed))
  end

  # --- Persistence API ---

  @doc "Create a new run record."
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a run's task list and progress."
  def update_task(run_id, task_id, updates) do
    case Repo.get(__MODULE__, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        tasks = merge_task(run.tasks, task_id, updates)
        run |> changeset(%{tasks: tasks}) |> Repo.update()
    end
  end

  defp parse_priority("high"), do: :high
  defp parse_priority("low"), do: :low
  defp parse_priority(_), do: :normal

  defp merge_task(tasks, task_id, updates) do
    Enum.map(tasks, fn task ->
      if task["id"] == task_id, do: Map.merge(task, updates), else: task
    end)
  end

  @doc "Update run progress (iteration, budget, status)."
  def update_progress(run_id, attrs) do
    case Repo.get(__MODULE__, run_id) do
      nil -> {:error, :not_found}
      run -> run |> changeset(attrs) |> Repo.update()
    end
  end

  @doc "Mark a run as completed with the final result."
  def complete(run_id, result_text) do
    update_progress(run_id, %{
      status: "completed",
      result: result_text,
      completed_at: DateTime.utc_now()
    })
  end

  @doc "Mark a run as failed."
  def fail(run_id, reason) do
    update_progress(run_id, %{
      status: "failed",
      result: "Error: #{inspect(reason)}",
      completed_at: DateTime.utc_now()
    })
  end

  @doc "Pause a running orchestration."
  def pause(run_id) do
    update_progress(run_id, %{
      status: "paused",
      paused_at: DateTime.utc_now()
    })
  end

  @doc "Get a run by ID."
  def get(run_id), do: Repo.get(__MODULE__, run_id)

  @doc "List runs for a project, newest first."
  def list_by_project(project_id) do
    from(r in __MODULE__,
      where: r.project_id == ^project_id,
      order_by: [desc: r.started_at]
    )
    |> Repo.all()
  end

  @doc "List active (running/paused) runs for a project."
  def list_active(project_id) do
    from(r in __MODULE__,
      where: r.project_id == ^project_id and r.status in ["running", "paused"],
      order_by: [desc: r.started_at]
    )
    |> Repo.all()
  end

  @doc """
  Build a resume snapshot from a persisted run.

  Returns a map with the state needed to rebuild the Orchestrator:
  - pending tasks (not yet completed)
  - completed results
  - budget state
  """
  def resume_snapshot(run_id) do
    case get(run_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status not in ["running", "paused"] ->
        {:error, {:not_resumable, status}}

      run ->
        completed =
          run.tasks
          |> Enum.filter(&(&1["status"] == "completed"))
          |> Enum.map(&{&1["id"], &1["result"]})

        completed_ids = MapSet.new(completed, fn {id, _} -> id end)

        pending =
          run.tasks
          |> Enum.reject(&(&1["status"] == "completed"))
          |> Enum.map(fn t ->
            %{
              id: t["id"],
              specialist: t["specialist"],
              input: t["input"],
              priority: parse_priority(t["priority"]),
              depends_on: t["depends_on"] || []
            }
          end)

        {:ok,
         %{
           run: run,
           pending_tasks: pending,
           completed: completed,
           completed_ids: completed_ids,
           budget_used: run.budget_used,
           budget_velocity: run.budget_velocity,
           iteration: run.iteration
         }}
    end
  end
end
