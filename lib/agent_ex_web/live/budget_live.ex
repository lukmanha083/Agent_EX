defmodule AgentExWeb.BudgetLive do
  use AgentExWeb, :live_view

  alias AgentEx.Budget

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <header class="flex items-center justify-between px-4 md:px-6 h-14 border-b border-gray-800 bg-gray-900/50 shrink-0">
        <div>
          <h1 class="text-base font-semibold text-white">Budget</h1>
          <p class="text-xs text-gray-500">
            <span class="text-indigo-400">{@project.name}</span>
            <span> — </span>Token usage and budget management
          </p>
        </div>
      </header>

      <div class="flex-1 overflow-y-auto p-4 md:p-6">
        <div class="mx-auto max-w-2xl space-y-6">
          <%!-- Monthly usage overview --%>
          <div class="grid grid-cols-3 gap-4">
            <div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
              <p class="text-xs text-gray-500 uppercase tracking-wider">Input tokens</p>
              <p class="text-xl font-mono text-white mt-1">{format_number(@monthly_usage.input)}</p>
            </div>
            <div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
              <p class="text-xs text-gray-500 uppercase tracking-wider">Output tokens</p>
              <p class="text-xl font-mono text-white mt-1">{format_number(@monthly_usage.output)}</p>
            </div>
            <div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
              <p class="text-xs text-gray-500 uppercase tracking-wider">Total this month</p>
              <p class="text-xl font-mono text-white mt-1">{format_number(@monthly_usage.total)}</p>
            </div>
          </div>

          <%!-- Budget bar --%>
          <div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-medium text-white">Monthly Budget</h2>
              <span class="text-xs font-mono text-gray-400">
                {format_remaining(@remaining)}
              </span>
            </div>
            <%= if @project.token_budget do %>
              <div class="w-full bg-gray-800 rounded-full h-3">
                <div
                  class={[
                    "h-3 rounded-full transition-all",
                    budget_bar_color(@usage_pct)
                  ]}
                  style={"width: #{min(@usage_pct, 100)}%"}
                />
              </div>
              <p class="text-xs text-gray-500 mt-2">
                {format_number(@monthly_usage.total)} / {format_number(@project.token_budget)} tokens ({@usage_pct}%)
              </p>
            <% else %>
              <p class="text-sm text-gray-500">No budget limit set — usage is unlimited.</p>
            <% end %>

            <.form for={@budget_form} phx-submit="update_budget" class="flex items-end gap-3 mt-4">
              <div class="flex-1">
                <label class="block text-sm font-medium text-gray-300 mb-1">Budget limit (tokens per month)</label>
                <input
                  type="number"
                  name="token_budget"
                  value={@budget_form["token_budget"]}
                  placeholder="e.g. 1000000"
                  min="0"
                  class="block w-full rounded-lg bg-gray-800 border border-gray-700 text-white focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 text-sm px-3 py-2"
                />
              </div>
              <.button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white mb-0.5">
                Update
              </.button>
            </.form>
            <p class="text-[10px] text-gray-500 mt-1">
              Leave empty or set to 0 for unlimited. Budget resets each calendar month.
            </p>
          </div>

          <%!-- Usage by model --%>
          <div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
            <h2 class="text-sm font-medium text-white mb-3">Usage by Model (this month)</h2>
            <%= if @model_breakdown == [] do %>
              <p class="text-sm text-gray-500 py-2">No usage recorded yet.</p>
            <% else %>
              <div class="space-y-2">
                <div
                  :for={row <- @model_breakdown}
                  class="flex items-center justify-between rounded-md bg-gray-800/50 px-3 py-2"
                >
                  <div>
                    <span class="text-sm text-white">{row.model}</span>
                    <span class="text-xs text-gray-500 ml-2">{row.provider}</span>
                  </div>
                  <div class="text-right">
                    <span class="text-sm font-mono text-white">{format_number(row.total)}</span>
                    <span class="text-xs text-gray-500 ml-1">tokens</span>
                    <span class="text-xs text-gray-600 ml-2">({row.calls} calls)</span>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- All time total --%>
          <div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
            <h2 class="text-sm font-medium text-white mb-1">All Time</h2>
            <p class="text-sm text-gray-400">
              <span class="font-mono text-white">{format_number(@total_usage.total)}</span> total tokens
              (<span class="font-mono">{format_number(@total_usage.input)}</span> input,
              <span class="font-mono">{format_number(@total_usage.output)}</span> output)
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    project = socket.assigns.current_project
    {:ok, load_budget_data(socket, project)}
  end

  @impl true
  def handle_event("update_budget", params, socket) do
    project = socket.assigns.project

    budget =
      case Integer.parse(params["token_budget"] || "") do
        {n, ""} when n > 0 -> n
        {0, ""} -> nil
        _ -> nil
      end

    case Budget.update_budget(project.id, budget) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(project: updated)
         |> load_budget_data(updated)
         |> put_flash(
           :info,
           if(budget,
             do: "Budget set to #{format_number(budget)} tokens",
             else: "Budget set to unlimited"
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update budget")}
    end
  end

  defp load_budget_data(socket, project) do
    monthly = Budget.usage_this_month(project.id)
    total = Budget.total_usage(project.id)
    remaining = Budget.budget_remaining(project.id)
    breakdown = Budget.usage_by_model(project.id)

    usage_pct =
      if project.token_budget && project.token_budget > 0,
        do: round(monthly.total / project.token_budget * 100),
        else: 0

    assign(socket,
      project: project,
      monthly_usage: monthly,
      total_usage: total,
      remaining: remaining,
      model_breakdown: breakdown,
      usage_pct: usage_pct,
      budget_form: %{"token_budget" => project.token_budget && to_string(project.token_budget)}
    )
  end

  defp format_number(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(_), do: "0"

  defp format_remaining(:unlimited), do: "unlimited"
  defp format_remaining(n), do: "#{format_number(n)} remaining"

  defp budget_bar_color(pct) when pct >= 90, do: "bg-red-500"
  defp budget_bar_color(pct) when pct >= 70, do: "bg-amber-500"
  defp budget_bar_color(_), do: "bg-indigo-500"
end
