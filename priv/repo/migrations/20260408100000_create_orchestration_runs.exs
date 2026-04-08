defmodule AgentEx.Repo.Migrations.CreateOrchestrationRuns do
  use Ecto.Migration

  def change do
    create table(:orchestration_runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, on_delete: :delete_all)
      add :user_id, :bigint
      add :goal, :text, null: false
      add :status, :string, default: "running", null: false

      # Task state (JSONB — full snapshot for resume)
      add :tasks, {:array, :map}, default: []
      add :dependency_graph, :map, default: %{}

      # Budget state
      add :budget_total, :integer
      add :budget_used, :integer, default: 0
      add :budget_velocity, :float, default: 0.0

      # Progress
      add :iteration, :integer, default: 0
      add :max_iterations, :integer, default: 30

      # Final result
      add :result, :text

      # Timing
      add :started_at, :utc_datetime_usec
      add :paused_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_runs, [:project_id])
    create index(:orchestration_runs, [:user_id])
    create index(:orchestration_runs, [:status])
  end
end
