defmodule AgentEx.Repo.Migrations.CreateOrchestrationTasks do
  use Ecto.Migration

  def change do
    create table(:orchestration_tasks) do
      add :run_id, :string, null: false
      add :title, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :agent, :string
      add :specialist, :string
      add :input, :text
      add :result, :text
      add :priority, :string, null: false, default: "normal"
      add :depends_on, {:array, :integer}, default: []
      add :metadata, :map, default: %{}
      add :usage, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestration_tasks, [:run_id])
    create index(:orchestration_tasks, [:run_id, :status])
  end
end
