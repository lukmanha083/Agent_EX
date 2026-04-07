defmodule AgentEx.Orchestrator.BudgetTracker do
  @moduledoc """
  Real-time budget intelligence for the orchestrator.

  Tracks token consumption, calculates velocity (EMA), projects remaining
  capacity, and determines the current budget zone. The zone is injected
  into the Planner's system prompt so the LLM naturally adjusts strategy.

  ## Budget Zones

  - `:explore` (>50% remaining) — full parallelism, deep research
  - `:focused` (20-50%) — reduce parallelism, skip non-critical tasks
  - `:converge` (<20%) — stop dispatching, synthesize from what you have
  - `:report` (~0%) — emit best-effort result + incomplete task summary
  """

  defstruct [
    :total,
    used: 0,
    task_count: 0,
    velocity: 0.0,
    zone: :explore
  ]

  @type zone :: :explore | :focused | :converge | :report
  @type t :: %__MODULE__{
          total: pos_integer(),
          used: non_neg_integer(),
          task_count: non_neg_integer(),
          velocity: float(),
          zone: zone()
        }

  @ema_alpha 0.3

  @doc "Create a new budget tracker with a total token budget."
  @spec new(pos_integer()) :: t()
  def new(total) when is_integer(total) and total > 0 do
    %__MODULE__{total: total}
  end

  @doc "Record token usage from a completed task. Updates velocity EMA and zone."
  @spec record(t(), pos_integer()) :: t()
  def record(%__MODULE__{} = bt, usage) when is_integer(usage) and usage >= 0 do
    new_used = bt.used + usage
    new_count = bt.task_count + 1
    new_velocity = @ema_alpha * usage + (1 - @ema_alpha) * bt.velocity

    %{bt | used: new_used, task_count: new_count, velocity: new_velocity}
    |> update_zone()
  end

  @doc "Remaining token budget."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{total: total, used: used}), do: max(total - used, 0)

  @doc "Percentage of budget remaining (0.0 - 100.0)."
  @spec percent_remaining(t()) :: float()
  def percent_remaining(%__MODULE__{total: total} = bt) do
    Float.round(remaining(bt) / total * 100, 1)
  end

  @doc "Projected number of tasks the remaining budget can support."
  @spec projected_tasks(t()) :: non_neg_integer()
  def projected_tasks(%__MODULE__{velocity: +0.0} = bt), do: remaining(bt)

  def projected_tasks(%__MODULE__{} = bt) do
    trunc(remaining(bt) / bt.velocity)
  end

  @doc "Current budget zone."
  @spec zone(t()) :: zone()
  def zone(%__MODULE__{zone: zone}), do: zone

  @doc "Max concurrency for the current zone."
  @spec max_concurrency_for_zone(t(), pos_integer()) :: non_neg_integer()
  def max_concurrency_for_zone(%__MODULE__{zone: :explore}, base), do: base
  def max_concurrency_for_zone(%__MODULE__{zone: :focused}, base), do: ceil(base / 2)
  def max_concurrency_for_zone(%__MODULE__{zone: :converge}, _base), do: 1
  def max_concurrency_for_zone(%__MODULE__{zone: :report}, _base), do: 0

  @doc "Render budget state as text for LLM system prompt injection."
  @spec to_prompt(t()) :: String.t()
  def to_prompt(%__MODULE__{} = bt) do
    """
    ## Budget Status
    - Remaining: #{remaining(bt)}/#{bt.total} tokens (#{percent_remaining(bt)}%)
    - Tasks completed: #{bt.task_count}
    - Avg tokens/task: #{round(bt.velocity)}
    - Projected remaining tasks: #{projected_tasks(bt)}
    - Zone: #{bt.zone |> Atom.to_string() |> String.upcase()}
    #{zone_instruction(bt.zone)}\
    """
  end

  defp update_zone(%__MODULE__{} = bt) do
    pct = percent_remaining(bt)

    zone =
      cond do
        pct > 50.0 -> :explore
        pct > 20.0 -> :focused
        pct > 5.0 -> :converge
        true -> :report
      end

    %{bt | zone: zone}
  end

  defp zone_instruction(:explore),
    do: "Full exploration mode — use parallel dispatch, deep research, broad coverage."

  defp zone_instruction(:focused),
    do: "Focused mode — reduce parallelism, skip non-critical tasks, prioritize high-value work."

  defp zone_instruction(:converge),
    do: "Converge mode — stop dispatching new tasks, synthesize results from what you have."

  defp zone_instruction(:report),
    do:
      "Report mode — produce final result immediately from available data. Note any incomplete tasks."
end
