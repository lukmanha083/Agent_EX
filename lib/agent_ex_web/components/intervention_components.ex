defmodule AgentExWeb.InterventionComponents do
  @moduledoc """
  Components for the intervention builder — handler cards, pipeline visualization,
  and decision matrix.
  """

  use Phoenix.Component

  import SaladUI.Badge
  import SaladUI.Button

  @available_handlers [
    %{
      id: "permission_handler",
      name: "Permission Handler",
      module: "AgentEx.Intervention.PermissionHandler",
      description: "Approve/reject based on tool kind (read auto-approved, write requires approval)",
      kind: :gate
    },
    %{
      id: "write_gate_handler",
      name: "Write Gate Handler",
      module: "AgentEx.Intervention.WriteGateHandler",
      description: "Block all write-kind tool calls unless explicitly allowed",
      kind: :gate
    },
    %{
      id: "log_handler",
      name: "Log Handler",
      module: "AgentEx.Intervention.LogHandler",
      description: "Log all tool calls before execution (always approves)",
      kind: :observer
    }
  ]

  def available_handlers, do: @available_handlers

  @doc "Renders the intervention pipeline builder."
  attr :pipeline, :list, default: []
  attr :available, :list, default: @available_handlers

  def intervention_pipeline(assigns) do
    ~H"""
    <div class="space-y-4">
      <!-- Active pipeline -->
      <div>
        <h3 class="text-sm font-medium text-white mb-3">Active Pipeline</h3>
        <%= if @pipeline == [] do %>
          <div class="flex items-center justify-center rounded-lg border-2 border-dashed border-gray-700 py-8">
            <p class="text-sm text-gray-500">No handlers in pipeline. Add handlers from below.</p>
          </div>
        <% else %>
          <div id="intervention-pipeline" phx-hook="Sortable" class="space-y-2">
            <.handler_card
              :for={{handler, idx} <- Enum.with_index(@pipeline)}
              handler={handler}
              index={idx}
              removable={true}
            />
          </div>
        <% end %>
      </div>

      <!-- Flow visualization -->
      <div :if={@pipeline != []} class="flex items-center gap-2 px-4 py-3 rounded-lg bg-gray-800/50">
        <span class="text-xs text-gray-400">Flow:</span>
        <span class="text-xs text-indigo-400">Tool Call</span>
        <span :for={handler <- @pipeline} class="flex items-center gap-2">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3 text-gray-600">
            <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
          </svg>
          <span class={[
            "text-xs",
            handler_kind(handler.id) == :gate && "text-amber-400",
            handler_kind(handler.id) == :observer && "text-emerald-400"
          ]}>
            {handler_short_name(handler.id)}
          </span>
        </span>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3 text-gray-600">
          <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
        </svg>
        <span class="text-xs text-emerald-400">Execute</span>
      </div>

      <!-- Available handlers -->
      <div>
        <h3 class="text-sm font-medium text-white mb-3">Available Handlers</h3>
        <div class="space-y-2">
          <.available_handler_card
            :for={handler <- @available}
            handler={handler}
            in_pipeline={handler.id in Enum.map(@pipeline, & &1.id)}
          />
        </div>
      </div>
    </div>
    """
  end

  @doc "Active handler card in the pipeline (draggable, removable)."
  attr :handler, :map, required: true
  attr :index, :integer, required: true
  attr :removable, :boolean, default: false

  def handler_card(assigns) do
    ~H"""
    <div
      class="flex items-center gap-3 rounded-lg border border-gray-700 bg-gray-800 px-3 py-2.5 cursor-move group"
      data-id={@handler.id}
    >
      <div class="text-gray-500 shrink-0">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
          <path fill-rule="evenodd" d="M2 3.75A.75.75 0 0 1 2.75 3h10.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 3.75ZM2 8a.75.75 0 0 1 .75-.75h10.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 8Zm0 4.25a.75.75 0 0 1 .75-.75h10.5a.75.75 0 0 1 0 1.5H2.75a.75.75 0 0 1-.75-.75Z" clip-rule="evenodd" />
        </svg>
      </div>

      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium text-white">{handler_display_name(@handler.id)}</span>
          <.badge variant={handler_badge_variant(@handler.id)}>
            {handler_kind_label(@handler.id)}
          </.badge>
        </div>
      </div>

      <button
        :if={@removable}
        type="button"
        phx-click="remove_handler"
        phx-value-id={@handler.id}
        class="p-1 rounded text-gray-500 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-all"
        aria-label="Remove handler"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
          <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
        </svg>
      </button>
    </div>
    """
  end

  @doc "Available handler card (addable to pipeline)."
  attr :handler, :map, required: true
  attr :in_pipeline, :boolean, default: false

  def available_handler_card(assigns) do
    ~H"""
    <div class="flex items-center justify-between rounded-lg border border-gray-800 bg-gray-900 px-4 py-3">
      <div>
        <div class="flex items-center gap-2 mb-0.5">
          <span class="text-sm font-medium text-white">{@handler.name}</span>
          <.badge variant={if @handler.kind == :gate, do: "default", else: "secondary"} class="text-[10px]">
            {to_string(@handler.kind)}
          </.badge>
        </div>
        <p class="text-xs text-gray-400">{@handler.description}</p>
      </div>

      <%= if @in_pipeline do %>
        <span class="text-xs text-gray-500 shrink-0 ml-3">Added</span>
      <% else %>
        <.button
          variant="outline"
          size="sm"
          phx-click="add_handler"
          phx-value-id={@handler.id}
          class="border-gray-700 text-gray-300 hover:bg-gray-800 shrink-0 ml-3"
        >
          Add
        </.button>
      <% end %>
    </div>
    """
  end

  # --- Helpers ---

  defp handler_display_name(id) do
    case Enum.find(@available_handlers, &(&1.id == id)) do
      %{name: name} -> name
      _ -> id
    end
  end

  defp handler_short_name(id) do
    case id do
      "permission_handler" -> "Permission"
      "write_gate_handler" -> "WriteGate"
      "log_handler" -> "Log"
      other -> other
    end
  end

  defp handler_kind(id) do
    case Enum.find(@available_handlers, &(&1.id == id)) do
      %{kind: kind} -> kind
      _ -> :observer
    end
  end

  defp handler_kind_label(id), do: to_string(handler_kind(id))

  defp handler_badge_variant(id) do
    case handler_kind(id) do
      :gate -> "default"
      :observer -> "secondary"
    end
  end
end
