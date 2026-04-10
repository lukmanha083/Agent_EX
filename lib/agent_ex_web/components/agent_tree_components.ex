defmodule AgentExWeb.AgentTreeComponents do
  @moduledoc """
  Vertical agent tree components for real-time orchestration visualization.

  Renders a tree of agent nodes with tool calls, status indicators, and
  sub-delegation nesting. Replaces the horizontal pipeline stages display
  during orchestrate runs.
  """

  use Phoenix.Component

  import SaladUI.Badge

  @doc """
  Renders the full agent tree with orchestrator root and specialist children.

  ## Assigns
  - `tree` — map of `%{task_id => node}` where node has agent/status/tools/children fields
  - `budget` — optional `%{percent: integer, zone: atom}` for budget display
  - `task_stats` — `%{completed: integer, total: integer}`
  """
  attr(:tree, :map, required: true)
  attr(:budget, :map, default: nil)
  attr(:task_stats, :map, default: %{completed: 0, total: 0})
  attr(:logs, :map, default: %{})
  attr(:expanded, :string, default: nil)

  def agent_tree(assigns) do
    ~H"""
    <div :if={@tree != %{}} id="agent-tree" phx-hook="AgentTree" class="mx-4 my-3 rounded-lg border border-gray-800 bg-gray-900/50 p-3 text-sm">
      <%!-- Orchestrator root node --%>
      <div class="flex items-center gap-2 mb-2">
        <span class="text-base" aria-hidden="true">&#x1F916;</span>
        <span class="font-semibold text-gray-200">Orchestrator</span>
        <.badge variant="outline" class="text-[10px] text-indigo-400 border-indigo-500/30">
          {orchestrator_status(@tree)}
        </.badge>
      </div>

      <%!-- Specialist children --%>
      <div class="ml-3 border-l border-gray-700 pl-3 space-y-2">
        <.agent_node
          :for={{task_id, node} <- sorted_nodes(@tree)}
          task_id={task_id}
          node={node}
          logs={Map.get(@logs, task_id, [])}
          expanded={@expanded == task_id}
        />
      </div>

      <%!-- Progress footer --%>
      <div class="mt-3 pt-2 border-t border-gray-800 flex items-center gap-3 text-xs text-gray-500">
        <span>Tasks: {@task_stats.completed}/{@task_stats.total}</span>
        <span :if={@budget}>
          Budget: {@budget.percent}%
          <.badge
            variant={zone_badge_variant(@budget.zone)}
            class="ml-1 text-[9px]"
          >
            {@budget.zone}
          </.badge>
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a single agent node with status, tool calls, and optional children.
  """
  attr(:task_id, :string, required: true)
  attr(:node, :map, required: true)
  attr(:logs, :list, default: [])
  attr(:expanded, :boolean, default: false)

  def agent_node(assigns) do
    ~H"""
    <div id={"agent-node-#{@task_id}"} class="group">
      <%!-- Agent header --%>
      <div class="flex items-center gap-2">
        <span class={["w-2 h-2 rounded-full shrink-0", node_status_dot(@node.status)]} />
        <span class="text-xs" aria-hidden="true">&#x1F916;</span>
        <span class="font-medium text-gray-300 text-xs">{@node.agent}</span>
        <span :if={@node[:model]} class="text-[10px] text-gray-600">{@node.model}</span>
        <button
          type="button"
          phx-click="toggle_agent_log"
          phx-value-id={@task_id}
          class={[
            "ml-auto cursor-pointer hover:opacity-80 transition-opacity",
            @expanded && "ring-1 ring-indigo-500 rounded"
          ]}
        >
          <.badge variant={node_badge_variant(@node.status)} class="text-[9px]">
            {format_status(@node.status)}
          </.badge>
        </button>
      </div>

      <%!-- Tool calls --%>
      <div :if={@node.tools != []} class="ml-6 mt-1 space-y-0.5">
        <div :for={tool <- @node.tools} class="flex items-center gap-1.5 text-xs">
          <span class={["w-1.5 h-1.5 rounded-full shrink-0", tool_status_dot(tool.status)]} />
          <span class="font-mono text-gray-500">{tool.name}</span>
          <span :if={tool[:duration_ms]} class="text-[10px] text-gray-600">
            {format_duration(tool.duration_ms)}
          </span>
        </div>
      </div>

      <%!-- Result preview (collapsed for completed) --%>
      <div
        :if={@node.status == :complete && @node[:result_preview]}
        class="ml-6 mt-1 text-[11px] text-gray-600 truncate max-w-md"
      >
        {String.slice(@node.result_preview, 0, 120)}
      </div>

      <%!-- Error message --%>
      <div
        :if={@node.status == :failed && @node[:error]}
        class="ml-6 mt-1 text-[11px] text-red-400 truncate max-w-md"
      >
        {String.slice(@node.error, 0, 120)}
      </div>

      <%!-- Expandable log panel --%>
      <.agent_log_panel :if={@expanded} logs={@logs} />

      <%!-- Sub-delegated children --%>
      <div :if={@node[:children] && @node.children != []} class="ml-5 mt-1 border-l border-gray-700/50 pl-3 space-y-1">
        <.agent_node
          :for={{child_id, child_node} <- @node.children}
          task_id={child_id}
          node={child_node}
        />
      </div>
    </div>
    """
  end

  @doc """
  Warning banner shown during long-running orchestration.
  """
  attr(:active, :boolean, default: false)

  def orchestration_banner(assigns) do
    ~H"""
    <div
      :if={@active}
      class="mx-4 my-2 px-3 py-2 rounded-lg bg-amber-900/30 border border-amber-700/40 flex items-center gap-2 text-xs text-amber-300"
    >
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4 shrink-0">
        <path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495ZM10 5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 5Zm0 9a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z" clip-rule="evenodd" />
      </svg>
      <span>Orchestration in progress — do not close this page while tasks are running</span>
    </div>
    """
  end

  @doc """
  Expandable log panel showing agent activity (tool calls, results).
  """
  attr(:logs, :list, required: true)

  def agent_log_panel(assigns) do
    ~H"""
    <div class="ml-6 mt-2 rounded-md border border-gray-800 bg-gray-950 p-2 max-h-60 overflow-y-auto font-mono text-[11px] space-y-1">
      <div :if={@logs == []} class="flex items-center gap-2 text-gray-600">
        <span class="w-1.5 h-1.5 rounded-full bg-yellow-500 animate-pulse shrink-0" />
        <span>Agent is working...</span>
      </div>
      <div :for={entry <- @logs} class="flex gap-2">
        <span class={["shrink-0", log_entry_color(entry.type)]}>
          {log_entry_icon(entry.type)}
        </span>
        <span class="text-gray-400 break-all">
          {format_log_entry(entry)}
        </span>
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp sorted_nodes(tree) do
    tree
    |> Enum.sort_by(fn {_id, node} -> node[:order] || 0 end)
  end

  defp orchestrator_status(tree) do
    cond do
      Enum.all?(tree, fn {_, n} -> n.status in [:complete, :failed] end) -> "done"
      Enum.any?(tree, fn {_, n} -> n.status in [:running, :thinking] end) -> "dispatching"
      true -> "planning"
    end
  end

  defp node_status_dot(:pending), do: "bg-gray-500"
  defp node_status_dot(:thinking), do: "bg-yellow-500 animate-pulse"
  defp node_status_dot(:running), do: "bg-yellow-500 animate-pulse"
  defp node_status_dot(:complete), do: "bg-green-500"
  defp node_status_dot(:failed), do: "bg-red-500"
  defp node_status_dot(_), do: "bg-gray-500"

  defp tool_status_dot(:running), do: "bg-yellow-400 animate-pulse"
  defp tool_status_dot(:complete), do: "bg-green-400"
  defp tool_status_dot(:error), do: "bg-red-400"
  defp tool_status_dot(_), do: "bg-gray-500"

  defp node_badge_variant(:pending), do: "secondary"
  defp node_badge_variant(:thinking), do: "default"
  defp node_badge_variant(:running), do: "default"
  defp node_badge_variant(:complete), do: "outline"
  defp node_badge_variant(:failed), do: "destructive"
  defp node_badge_variant(_), do: "secondary"

  defp zone_badge_variant(:explore), do: "default"
  defp zone_badge_variant(:focused), do: "secondary"
  defp zone_badge_variant(:converge), do: "outline"
  defp zone_badge_variant(:report), do: "destructive"
  defp zone_badge_variant(_), do: "secondary"

  defp format_status(:pending), do: "pending"
  defp format_status(:thinking), do: "thinking"
  defp format_status(:running), do: "running"
  defp format_status(:complete), do: "complete"
  defp format_status(:failed), do: "failed"
  defp format_status(other), do: to_string(other)

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp log_entry_icon(:tool_call), do: ">"
  defp log_entry_icon(:tool_result), do: "<"
  defp log_entry_icon(:result), do: "="
  defp log_entry_icon(_), do: "-"

  defp log_entry_color(:tool_call), do: "text-yellow-500"
  defp log_entry_color(:tool_result), do: "text-green-500"
  defp log_entry_color(:result), do: "text-indigo-400"
  defp log_entry_color(_), do: "text-gray-500"

  defp format_log_entry(%{type: :tool_call, tool: tool, args: args}) do
    preview = if args, do: String.slice(to_string(args), 0, 120), else: ""
    "#{tool}(#{preview})"
  end

  defp format_log_entry(%{type: :tool_result, content: content, is_error: true}) do
    "ERR: #{content || "unknown error"}"
  end

  defp format_log_entry(%{type: :tool_result, content: content}) do
    content || "ok"
  end

  defp format_log_entry(%{type: :result, content: content}) do
    "Done: #{content || "completed"}"
  end

  defp format_log_entry(_), do: "..."
end
