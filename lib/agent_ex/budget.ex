defmodule AgentEx.Budget do
  @moduledoc """
  Token usage tracking and budget enforcement per project.

  Records input/output token counts from each API call and checks
  whether a project has exceeded its budget.
  """

  import Ecto.Query

  alias AgentEx.Budget.TokenUsage
  alias AgentEx.Projects.Project
  alias AgentEx.Repo

  @doc "Record a token usage entry."
  @spec record_usage(map()) :: {:ok, TokenUsage.t()} | {:error, Ecto.Changeset.t()}
  def record_usage(attrs) do
    %TokenUsage{}
    |> TokenUsage.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get total usage for a project (all time)."
  @spec total_usage(integer()) :: %{input: integer(), output: integer(), total: integer()}
  def total_usage(project_id) do
    query =
      from(u in TokenUsage,
        where: u.project_id == ^project_id,
        select: %{
          input: coalesce(sum(u.input_tokens), 0),
          output: coalesce(sum(u.output_tokens), 0)
        }
      )

    result = Repo.one(query) || %{input: 0, output: 0}
    Map.put(result, :total, result.input + result.output)
  end

  @doc "Get usage for a project this calendar month."
  @spec usage_this_month(integer()) :: %{input: integer(), output: integer(), total: integer()}
  def usage_this_month(project_id) do
    now = DateTime.utc_now()
    month_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

    query =
      from(u in TokenUsage,
        where: u.project_id == ^project_id and u.inserted_at >= ^month_start,
        select: %{
          input: coalesce(sum(u.input_tokens), 0),
          output: coalesce(sum(u.output_tokens), 0)
        }
      )

    result = Repo.one(query) || %{input: 0, output: 0}
    Map.put(result, :total, result.input + result.output)
  end

  @doc "Get usage breakdown by model for a project this month."
  @spec usage_by_model(integer()) :: [map()]
  def usage_by_model(project_id) do
    now = DateTime.utc_now()
    month_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

    from(u in TokenUsage,
      where: u.project_id == ^project_id and u.inserted_at >= ^month_start,
      group_by: [u.provider, u.model],
      select: %{
        provider: u.provider,
        model: u.model,
        input: coalesce(sum(u.input_tokens), 0),
        output: coalesce(sum(u.output_tokens), 0),
        calls: count(u.id)
      },
      order_by: [desc: count(u.id)]
    )
    |> Repo.all()
    |> Enum.map(fn row -> Map.put(row, :total, row.input + row.output) end)
  end

  @doc "Get remaining budget tokens. Returns `:unlimited` if no budget set."
  @spec budget_remaining(integer()) :: :unlimited | integer()
  def budget_remaining(project_id) do
    case Repo.get(Project, project_id) do
      %Project{token_budget: nil} ->
        :unlimited

      %Project{token_budget: budget} ->
        used = usage_this_month(project_id).total
        max(budget - used, 0)
    end
  end

  @doc "Check if the project has exceeded its monthly token budget."
  @spec budget_exceeded?(integer()) :: boolean()
  def budget_exceeded?(project_id) do
    case budget_remaining(project_id) do
      :unlimited -> false
      remaining -> remaining <= 0
    end
  end

  @doc "Update the token budget for a project."
  @spec update_budget(integer(), integer() | nil) :: {:ok, Project.t()} | {:error, term()}
  def update_budget(project_id, budget) do
    case Repo.get(Project, project_id) do
      nil ->
        {:error, :not_found}

      project ->
        project
        |> Project.update_changeset(%{token_budget: budget})
        |> Repo.update()
    end
  end
end
