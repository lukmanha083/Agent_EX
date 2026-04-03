defmodule AgentExWeb.WorkflowComponents do
  @moduledoc """
  Components for the workflow builder — node palette, node cards, workflow list,
  and configuration panels.
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]

  @node_types [
    %{type: "trigger", label: "Trigger", icon: "hero-signal", category: "io", color: "emerald"},
    %{
      type: "http_request",
      label: "HTTP Request",
      icon: "hero-globe-alt",
      category: "io",
      color: "blue"
    },
    %{
      type: "json_extract",
      label: "Extract",
      icon: "hero-funnel",
      category: "data",
      color: "amber"
    },
    %{
      type: "json_transform",
      label: "Transform",
      icon: "hero-arrows-right-left",
      category: "data",
      color: "amber"
    },
    %{
      type: "json_filter",
      label: "Filter",
      icon: "hero-adjustments-horizontal",
      category: "data",
      color: "amber"
    },
    %{
      type: "json_merge",
      label: "Merge Data",
      icon: "hero-arrows-pointing-in",
      category: "data",
      color: "amber"
    },
    %{type: "set", label: "Set Values", icon: "hero-pencil-square", category: "data", color: "amber"},
    %{type: "code", label: "Code", icon: "hero-code-bracket", category: "data", color: "amber"},
    %{
      type: "if_branch",
      label: "IF",
      icon: "hero-arrows-pointing-out",
      category: "flow",
      color: "purple"
    },
    %{
      type: "switch",
      label: "Switch",
      icon: "hero-queue-list",
      category: "flow",
      color: "purple"
    },
    %{
      type: "split",
      label: "Split",
      icon: "hero-scissors",
      category: "flow",
      color: "purple"
    },
    %{type: "merge", label: "Merge", icon: "hero-inbox-stack", category: "flow", color: "purple"},
    %{type: "agent", label: "Agent", icon: "hero-cpu-chip", category: "io", color: "rose"},
    %{type: "tool", label: "Tool", icon: "hero-wrench", category: "io", color: "blue"},
    %{type: "output", label: "Output", icon: "hero-arrow-down-tray", category: "io", color: "emerald"}
  ]

  @doc "Renders the workflow list page."
  attr(:workflows, :list, required: true)

  def workflow_list(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between mb-2">
        <p class="text-sm text-gray-400">
          Static pipelines — deterministic data transforms at zero token cost
        </p>
        <button
          type="button"
          phx-click="new_workflow"
          class="inline-flex items-center gap-1.5 rounded-md bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 transition-colors"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3.5 h-3.5"
          >
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New Workflow
        </button>
      </div>

      <%= if @workflows == [] do %>
        <div class="flex flex-col items-center justify-center py-12 text-center">
          <div class="flex h-12 w-12 items-center justify-center rounded-full bg-gray-800 mb-3">
            <.icon name="hero-squares-2x2" class="w-5 h-5 text-gray-500" />
          </div>
          <p class="text-sm text-gray-500 mb-1">No workflows yet</p>
          <p class="text-xs text-gray-600">
            Create a workflow to chain data operations without LLM tokens
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
          <.workflow_card :for={workflow <- @workflows} workflow={workflow} />
        </div>
      <% end %>
    </div>
    """
  end

  @doc "Renders a single workflow card."
  attr(:workflow, :map, required: true)

  def workflow_card(assigns) do
    ~H"""
    <div
      phx-click="edit_workflow"
      phx-value-id={@workflow.id}
      class="group relative rounded-lg border border-gray-800 bg-gray-900/50 p-4 hover:border-gray-700 transition-colors cursor-pointer"
    >
      <div class="flex items-start justify-between">
        <div class="flex-1 min-w-0">
          <h3 class="text-sm font-medium text-white truncate">{@workflow.name}</h3>
          <p :if={@workflow.description} class="mt-1 text-xs text-gray-500 line-clamp-2">
            {@workflow.description}
          </p>
        </div>
        <div class="flex items-center gap-1 ml-2 opacity-0 group-hover:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click="edit_workflow"
            phx-value-id={@workflow.id}
            class="p-1.5 rounded-md text-gray-500 hover:text-white hover:bg-gray-800 transition-colors"
            aria-label="Edit workflow"
          >
            <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="delete_workflow"
            phx-value-id={@workflow.id}
            data-confirm="Delete this workflow?"
            class="p-1.5 rounded-md text-gray-500 hover:text-red-400 hover:bg-gray-800 transition-colors"
            aria-label="Delete workflow"
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
      <div class="mt-3 flex items-center gap-3 text-[11px] text-gray-600">
        <span>{length(@workflow.nodes)} nodes</span>
        <span>{length(@workflow.edges)} edges</span>
      </div>
      <div class="mt-2 flex gap-1 flex-wrap">
        <span
          :for={type <- unique_node_types(@workflow.nodes)}
          class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-gray-800 text-gray-400"
        >
          {type}
        </span>
      </div>
    </div>
    """
  end

  @doc "Renders the node type palette for the visual editor."
  def node_palette(assigns) do
    assigns = assign(assigns, :node_types, @node_types)

    ~H"""
    <div class="space-y-3">
      <p class="text-[11px] font-medium text-gray-500 uppercase tracking-wider">
        I/O
      </p>
      <div class="grid grid-cols-2 gap-1.5">
        <.palette_item
          :for={node <- Enum.filter(@node_types, &(&1.category == "io"))}
          node={node}
        />
      </div>

      <p class="text-[11px] font-medium text-gray-500 uppercase tracking-wider pt-2">
        Data
      </p>
      <div class="grid grid-cols-2 gap-1.5">
        <.palette_item
          :for={node <- Enum.filter(@node_types, &(&1.category == "data"))}
          node={node}
        />
      </div>

      <p class="text-[11px] font-medium text-gray-500 uppercase tracking-wider pt-2">
        Flow
      </p>
      <div class="grid grid-cols-2 gap-1.5">
        <.palette_item
          :for={node <- Enum.filter(@node_types, &(&1.category == "flow"))}
          node={node}
        />
      </div>
    </div>
    """
  end

  attr(:node, :map, required: true)

  defp palette_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="add_node"
      phx-value-type={@node.type}
      class="flex items-center gap-1.5 px-2 py-1.5 rounded-md text-xs text-gray-400 hover:text-white hover:bg-gray-800 transition-colors border border-gray-800 hover:border-gray-700"
    >
      <.icon name={@node.icon} class="w-3.5 h-3.5" />
      <span class="truncate">{@node.label}</span>
    </button>
    """
  end

  @doc "Renders a node config panel for editing a selected node."
  attr(:node, :map, default: nil)
  attr(:agents, :list, default: [])
  attr(:tools, :list, default: [])

  def node_config_panel(assigns) do
    ~H"""
    <div :if={@node} class="space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-medium text-white truncate">{@node.label || @node.type}</h3>
        <div class="flex items-center gap-0.5 shrink-0">
          <button
            type="button"
            phx-click="delete_node"
            phx-value-id={@node.id}
            class="p-1 rounded-md text-gray-500 hover:text-red-400 hover:bg-gray-800"
            title="Delete node"
          >
            <.icon name="hero-trash" class="w-4 h-4" />
          </button>
          <button
            type="button"
            phx-click="deselect_node"
            class="p-1 rounded-md text-gray-500 hover:text-white hover:bg-gray-800"
            title="Close"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <div class="space-y-2">
        <label class="block text-xs text-gray-500">Label</label>
        <input
          type="text"
          value={@node.label || ""}
          phx-blur="update_node_label"
          phx-value-id={@node.id}
          class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
        />
      </div>

      <.node_type_config node={@node} agents={@agents} tools={@tools} />
    </div>

    <div :if={!@node} class="flex flex-col items-center justify-center py-8 text-center">
      <p class="text-xs text-gray-600">Select a node to configure</p>
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:agents, :list, default: [])
  attr(:tools, :list, default: [])

  defp node_type_config(%{node: %{type: :trigger}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="block text-xs text-gray-500">Trigger Type</label>
      <select
        phx-change="update_node_config"
        phx-value-id={@node.id}
        phx-value-key="type"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      >
        <option value="manual" selected={@node.config["type"] == "manual"}>Manual</option>
        <option value="cron" selected={@node.config["type"] == "cron"}>Cron Schedule</option>
        <option value="webhook" selected={@node.config["type"] == "webhook"}>Webhook</option>
      </select>
    </div>
    """
  end

  defp node_type_config(%{node: %{type: :http_request}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="block text-xs text-gray-500">Method</label>
      <select
        phx-change="update_node_config"
        phx-value-id={@node.id}
        phx-value-key="method"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      >
        <option :for={m <- ~w(GET POST PUT PATCH DELETE)} value={m} selected={@node.config["method"] == m}>
          {m}
        </option>
      </select>
      <label class="block text-xs text-gray-500">URL</label>
      <input
        type="text"
        value={@node.config["url"] || ""}
        placeholder="https://api.example.com/{{trigger.param}}"
        phx-blur="update_node_config_value"
        phx-value-id={@node.id}
        phx-value-key="url"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      />
    </div>
    """
  end

  defp node_type_config(%{node: %{type: :json_extract}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="block text-xs text-gray-500">Paths (one per line)</label>
      <textarea
        phx-blur="update_node_config_value"
        phx-value-id={@node.id}
        phx-value-key="paths"
        rows="3"
        placeholder={"data.price\ndata.volume\nmeta.timestamp"}
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 font-mono"
      >{format_paths(@node.config["paths"])}</textarea>
    </div>
    """
  end

  defp node_type_config(%{node: %{type: :if_branch}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="block text-xs text-gray-500">Condition Path</label>
      <input
        type="text"
        value={@node.config["path"] || ""}
        placeholder={"{{prev_node.field}}"}
        phx-blur="update_node_config_value"
        phx-value-id={@node.id}
        phx-value-key="path"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 font-mono"
      />
      <label class="block text-xs text-gray-500">Operator</label>
      <select
        phx-change="update_node_config"
        phx-value-id={@node.id}
        phx-value-key="operator"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      >
        <option :for={op <- ~w(== != > < >= <= contains matches empty not_empty)} value={op} selected={@node.config["operator"] == op}>
          {op}
        </option>
      </select>
      <label class="block text-xs text-gray-500">Expected Value</label>
      <input
        type="text"
        value={@node.config["expected"] || ""}
        phx-blur="update_node_config_value"
        phx-value-id={@node.id}
        phx-value-key="expected"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      />
    </div>
    """
  end

  defp node_type_config(%{node: %{type: :set}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="block text-xs text-gray-500">Values (JSON)</label>
      <textarea
        phx-blur="update_node_config_json"
        phx-value-id={@node.id}
        phx-value-key="values"
        rows="3"
        placeholder={~s|{"status": "processed"}|}
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 font-mono"
      >{Jason.encode!(@node.config["values"] || %{}, pretty: true)}</textarea>
    </div>
    """
  end

  defp node_type_config(%{node: %{type: :agent}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="block text-xs text-gray-500">Agent</label>
      <select
        phx-change="update_node_config"
        phx-value-id={@node.id}
        phx-value-key="agent_id"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      >
        <option value="">Select agent...</option>
        <option :for={agent <- @agents} value={agent.id} selected={@node.config["agent_id"] == agent.id}>
          {agent.name}
        </option>
      </select>
      <label class="block text-xs text-gray-500">Task Template</label>
      <textarea
        phx-blur="update_node_config_value"
        phx-value-id={@node.id}
        phx-value-key="task_template"
        rows="2"
        placeholder="Analyze: {{input}}"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      >{@node.config["task_template"] || ""}</textarea>
    </div>
    """
  end

  defp node_type_config(%{node: %{type: :output}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="block text-xs text-gray-500">Format</label>
      <select
        phx-change="update_node_config"
        phx-value-id={@node.id}
        phx-value-key="format"
        class="w-full rounded-md bg-gray-800 border border-gray-700 text-sm text-white px-3 py-1.5 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
      >
        <option value="json" selected={@node.config["format"] == "json"}>JSON</option>
        <option value="text" selected={@node.config["format"] == "text"}>Text</option>
        <option value="table" selected={@node.config["format"] == "table"}>Table</option>
      </select>
    </div>
    """
  end

  defp node_type_config(assigns) do
    ~H"""
    <p class="text-xs text-gray-600">No additional config for this node type.</p>
    """
  end

  @doc "Canvas rendering of workflow nodes and edges."
  attr(:nodes, :list, required: true)
  attr(:edges, :list, required: true)
  attr(:selected_node_id, :string, default: nil)

  def workflow_canvas(assigns) do
    assigns = assign(assigns, :node_type_map, Map.new(@node_types, &{&1.type, &1}))

    ~H"""
    <div
      id="workflow-canvas"
      phx-hook="WorkflowEditor"
      class="relative w-full h-full min-h-[500px] bg-gray-950 rounded-lg border border-gray-800 overflow-auto"
      data-edges={Jason.encode!(Enum.map(@edges, &edge_to_json/1))}
    >
      <!-- SVG layer for edges — drawn entirely by JS using real DOM positions -->
      <svg id="workflow-svg" class="absolute inset-0 pointer-events-none" style="z-index: 1; width: 4000px; height: 4000px;">
        <!-- Edge paths injected by JS -->
        <g id="edge-group"></g>
        <!-- Temp line drawn by JS during drag-to-connect -->
        <line id="temp-edge" x1="0" y1="0" x2="0" y2="0" stroke="#6366f1" stroke-width="2" stroke-dasharray="6,4" class="hidden" />
      </svg>
      <!-- Nodes layer -->
      <div :for={node <- @nodes} class="absolute" style={"left: #{node.position["x"] || 0}px; top: #{node.position["y"] || 0}px; z-index: 2;"}>
        <.canvas_node
          node={node}
          meta={Map.get(@node_type_map, to_string(node.type), %{})}
          selected={@selected_node_id == node.id}
        />
      </div>
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:meta, :map, required: true)
  attr(:selected, :boolean, default: false)

  defp canvas_node(assigns) do
    assigns =
      assign(assigns,
        output_ports: output_ports(assigns.node),
        is_branch: assigns.node.type in [:if_branch, :switch]
      )

    ~H"""
    <div
      phx-click="select_node"
      phx-value-id={@node.id}
      data-node-id={@node.id}
      class={[
        "relative flex items-center gap-2 px-5 rounded-lg border cursor-pointer min-w-[120px] select-none transition-colors",
        @is_branch && "py-4" || "py-2",
        @selected && "border-indigo-500 bg-gray-800 ring-1 ring-indigo-500/50" ||
          "border-gray-700 bg-gray-900 hover:border-gray-600"
      ]}
    >
      <!-- Input port (left side) — not on trigger nodes -->
      <div
        :if={@node.type != :trigger}
        data-port-in={@node.id}
        class="absolute -left-[7px] top-1/2 -translate-y-1/2 w-[14px] h-[14px] rounded-full border-2 border-gray-600 bg-gray-800 hover:border-indigo-400 hover:bg-indigo-900 transition-colors cursor-crosshair z-10"
        title="Input"
      />
      <!-- Node content -->
      <.icon :if={@meta[:icon]} name={@meta.icon} class="w-4 h-4 text-gray-400 shrink-0" />
      <span class="text-xs text-white truncate">{@node.label || @meta[:label] || @node.type}</span>
      <!-- Output port(s) (right side) — not on output nodes -->
      <div
        :for={{port_id, port_label, offset_class} <- @output_ports}
        data-port-out={@node.id}
        data-port-name={port_id}
        class={[
          "absolute -right-[7px] w-[14px] h-[14px] rounded-full border-2 border-gray-600 bg-gray-800 hover:border-emerald-400 hover:bg-emerald-900 transition-colors cursor-crosshair z-10",
          offset_class
        ]}
        title={port_label}
      >
        <!-- Port label for branch outputs -->
        <span :if={port_id != "output"} class="absolute left-[-28px] top-1/2 -translate-y-1/2 text-[9px] text-gray-500 pointer-events-none select-none whitespace-nowrap">
          {port_label}
        </span>
      </div>
    </div>
    """
  end

  defp output_ports(%{type: :output}), do: []

  defp output_ports(%{type: :if_branch}) do
    [{"true", "T", "top-[8px]"}, {"false", "F", "bottom-[8px]"}]
  end

  defp output_ports(%{type: :switch}), do: [{"output", "Output", "top-1/2 -translate-y-1/2"}]

  defp output_ports(_node), do: [{"output", "Output", "top-1/2 -translate-y-1/2"}]

  # --- Helpers ---

  defp unique_node_types(nodes) do
    nodes
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp format_paths(nil), do: ""
  defp format_paths(paths) when is_list(paths), do: Enum.join(paths, "\n")
  defp format_paths(paths), do: to_string(paths)

  defp edge_to_json(edge) do
    %{
      id: edge.id,
      source_node_id: edge.source_node_id,
      target_node_id: edge.target_node_id,
      source_port: edge.source_port,
      target_port: edge.target_port
    }
  end
end
