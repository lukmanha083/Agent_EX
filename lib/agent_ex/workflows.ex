defmodule AgentEx.Workflows do
  @moduledoc """
  Context for workflow CRUD operations.
  Postgres-backed persistence with ON DELETE CASCADE from projects.
  """

  import Ecto.Query

  alias AgentEx.Repo
  alias AgentEx.Workflow

  @doc "Create a new workflow."
  def create_workflow(attrs) do
    %Workflow{}
    |> Workflow.changeset(attrs)
    |> Repo.insert()
    |> decode_result()
  end

  @doc "Get a workflow by ID, scoped to a project."
  def get_workflow(project_id, workflow_id) do
    Workflow
    |> where([w], w.id == ^workflow_id and w.project_id == ^project_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      workflow -> {:ok, Workflow.decode(workflow)}
    end
  end

  @doc "List all workflows for a project, newest first."
  def list_workflows(project_id) do
    Workflow
    |> where([w], w.project_id == ^project_id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
    |> Enum.map(&Workflow.decode/1)
  end

  @doc "Update an existing workflow."
  def update_workflow(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.update_changeset(attrs)
    |> Repo.update()
    |> decode_result()
  end

  @doc "Delete a workflow."
  def delete_workflow(%Workflow{} = workflow) do
    Repo.delete(workflow)
  end

  @doc "Delete a workflow by project_id and workflow_id."
  def delete_workflow(project_id, workflow_id) do
    Workflow
    |> where([w], w.id == ^workflow_id and w.project_id == ^project_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      workflow -> Repo.delete(workflow)
    end
  end

  defp decode_result({:ok, workflow}), do: {:ok, Workflow.decode(workflow)}
  defp decode_result(error), do: error
end
