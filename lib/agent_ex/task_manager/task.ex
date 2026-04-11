defmodule AgentEx.TaskManager.Task do
  @moduledoc """
  Ecto schema for orchestration tasks.

  Each task belongs to a run and tracks its lifecycle from pending through
  completion. Tasks can have priorities and dependencies on other tasks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending in_progress completed failed)
  @priorities ~w(high normal low)

  schema "orchestration_tasks" do
    field :run_id, :string
    field :title, :string
    field :status, :string, default: "pending"
    field :agent, :string
    field :specialist, :string
    field :input, :string
    field :result, :string
    field :priority, :string, default: "normal"
    field :depends_on, {:array, :integer}, default: []
    field :metadata, :map, default: %{}
    field :usage, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields [
    :run_id,
    :title,
    :status,
    :agent,
    :specialist,
    :input,
    :result,
    :priority,
    :depends_on,
    :metadata,
    :usage
  ]

  @update_fields [:status, :agent, :result, :priority, :depends_on, :metadata, :usage]

  @doc "Changeset for creating a new task."
  def changeset(task, attrs) do
    task
    |> cast(attrs, @create_fields)
    |> validate_required([:run_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
  end

  @doc "Changeset for updating an existing task."
  def update_changeset(task, attrs) do
    task
    |> cast(attrs, @update_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
  end
end
