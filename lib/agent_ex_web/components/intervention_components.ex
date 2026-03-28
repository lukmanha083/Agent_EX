defmodule AgentExWeb.InterventionComponents do
  @moduledoc """
  Embeddable intervention pipeline section for the agent editor.
  Handlers are toggled on/off per agent with per-handler configuration.
  Active pipeline order is reorderable via drag-and-drop.
  """

  use Phoenix.Component

  import SaladUI.Badge

  @available_handlers [
    %{
      id: "permission_handler",
      name: "Permission Handler",
      description: "Auto-approve read tools, reject all write tools",
      kind: :gate,
      configurable: false
    },
    %{
      id: "write_gate_handler",
      name: "Write Gate Handler",
      description: "Block writes unless tool name is in the allowlist",
      kind: :gate,
      configurable: true
    },
    %{
      id: "log_handler",
      name: "Log Handler",
      description: "Log all tool calls (always approves)",
      kind: :observer,
      configurable: false
    }
  ]

  def available_handlers, do: @available_handlers

  def handler_meta(id), do: Enum.find(@available_handlers, &(&1.id == id))

  @doc "Intervention pipeline section embedded in the agent editor."
  attr :pipeline, :list, default: []

  def intervention_section(assigns) do
    active_ids = MapSet.new(assigns.pipeline, & &1["id"])
    inactive = Enum.reject(@available_handlers, &MapSet.member?(active_ids, &1.id))

    active =
      Enum.map(assigns.pipeline, fn entry ->
        meta = handler_meta(entry["id"])
        if meta, do: Map.merge(meta, %{config: entry}), else: nil
      end)
      |> Enum.reject(&is_nil/1)

    assigns = assign(assigns, active: active, inactive: inactive)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-medium text-white">Intervention Pipeline</h3>
        <span class="text-[10px] text-gray-500">
          {length(@active)} active
        </span>
      </div>

      <p class="text-xs text-gray-500">
        Handlers run in order before each tool call. Gates can block execution; observers only log.
      </p>

      <%!-- Active pipeline (drag-and-drop reorderable) --%>
      <%= if @active != [] do %>
        <div id="intervention-pipeline" phx-hook="Sortable" class="space-y-1.5">
          <.pipeline_handler_card
            :for={{handler, idx} <- Enum.with_index(@active)}
            handler={handler}
            index={idx}
            active={true}
          />
        </div>

        <div class="flex items-center gap-1.5 px-3 py-2 rounded bg-gray-800/50">
          <span class="text-[10px] text-gray-500">Flow:</span>
          <span class="text-[10px] text-indigo-400">Tool Call</span>
          <span :for={handler <- @active} class="flex items-center gap-1">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5 text-gray-600">
              <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
            </svg>
            <span class={[
              "text-[10px]",
              handler.kind == :gate && "text-amber-400",
              handler.kind == :observer && "text-emerald-400"
            ]}>
              {short_name(handler.id)}
            </span>
          </span>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5 text-gray-600">
            <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
          </svg>
          <span class="text-[10px] text-emerald-400">Execute</span>
        </div>
      <% end %>

      <%!-- Inactive handlers (available to add) --%>
      <%= if @inactive != [] do %>
        <div class="space-y-1.5">
          <.pipeline_handler_card
            :for={handler <- @inactive}
            handler={handler}
            index={0}
            active={false}
          />
        </div>
      <% end %>
    </div>
    """
  end

  @doc "Sandbox boundary section embedded in the agent editor."
  attr :sandbox, :map, default: %{}

  def sandbox_section(assigns) do
    assigns =
      assign(assigns,
        root_path: assigns.sandbox["root_path"] || "",
        disallowed_commands: assigns.sandbox["disallowed_commands"] || []
      )

    ~H"""
    <div class="space-y-3">
      <div>
        <h3 class="text-sm font-medium text-white">Sandbox Boundary</h3>
        <p class="text-xs text-gray-500 mt-1">
          Restrict where this agent's tools can operate.
        </p>
      </div>

      <%!-- Root path --%>
      <div>
        <label class="block text-xs font-medium text-gray-300 mb-1">Root Directory</label>
        <div class="flex gap-2">
          <input
            type="text"
            name="sandbox_root_path"
            value={@root_path}
            placeholder="/home/user/project"
            phx-blur="update_sandbox_root"
            phx-keydown="update_sandbox_root"
            phx-key="Enter"
            class="flex-1 rounded-md border border-gray-700 bg-gray-800 px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
          />
        </div>
        <p class="text-[10px] text-gray-500 mt-1">
          File tools will be confined to this directory. Leave empty for no restriction.
        </p>
      </div>

      <%!-- Disallowed commands --%>
      <div>
        <label class="block text-xs font-medium text-gray-300 mb-1">Disallowed Commands</label>
        <div class="flex gap-2">
          <input
            id="cmd-input"
            type="text"
            placeholder="e.g. rm, mv, drop, delete"
            phx-keydown="add_disallowed_command"
            phx-key="Enter"
            phx-hook="ClearOnEnter"
            class="flex-1 rounded-md border border-gray-700 bg-gray-800 px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
          />
        </div>
        <p class="text-[10px] text-gray-500 mt-1">
          Press Enter to add. These commands will be blocked from execution by shell and SQL tools.
        </p>

        <%= if @disallowed_commands != [] do %>
          <div class="flex flex-wrap gap-1.5 mt-2">
            <span
              :for={cmd <- @disallowed_commands}
              class="inline-flex items-center gap-1 rounded-md bg-red-500/10 border border-red-500/20 px-2 py-0.5 text-xs text-red-300"
            >
              <code class="font-mono">{cmd}</code>
              <button
                type="button"
                phx-click="remove_disallowed_command"
                phx-value-cmd={cmd}
                class="text-red-400/50 hover:text-red-300 transition-colors"
                aria-label={"Remove #{cmd}"}
              >
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3">
                  <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
                </svg>
              </button>
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :handler, :map, required: true
  attr :index, :integer, required: true
  attr :active, :boolean, required: true

  defp pipeline_handler_card(assigns) do
    ~H"""
    <div class={["rounded-md border transition-colors", @active && "border-gray-700 bg-gray-800", not @active && "border-gray-800/50 bg-gray-900/50"]}>
      <div
        class={["flex items-center gap-2.5 px-3 py-2", @active && "cursor-move"]}
        data-id={if @active, do: @handler.id}
      >
        <%!-- Drag handle (active only) --%>
        <div :if={@active} class="text-gray-500 shrink-0">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
            <path fill-rule="evenodd" d="M2 3.75A.75.75 0 0 1 2.75 3h10.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 3.75ZM2 8a.75.75 0 0 1 .75-.75h10.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 8Zm0 4.25a.75.75 0 0 1 .75-.75h10.5a.75.75 0 0 1 0 1.5H2.75a.75.75 0 0 1-.75-.75Z" clip-rule="evenodd" />
          </svg>
        </div>

        <%!-- Info --%>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-1.5">
            <span class={["text-xs font-medium", @active && "text-white", not @active && "text-gray-400"]}>
              {@handler.name}
            </span>
            <.badge
              variant={if @handler.kind == :gate, do: "default", else: "secondary"}
              class="text-[9px] px-1 py-0"
            >
              {to_string(@handler.kind)}
            </.badge>
          </div>
          <p class="text-[10px] text-gray-500 mt-0.5">{@handler.description}</p>
        </div>

        <%!-- Toggle --%>
        <button
          type="button"
          phx-click={if @active, do: "remove_handler", else: "add_handler"}
          phx-value-id={@handler.id}
          class="shrink-0"
          aria-label={if @active, do: "Remove #{@handler.name}", else: "Add #{@handler.name}"}
        >
          <div class={[
            "relative w-8 h-[18px] rounded-full transition-colors",
            @active && "bg-indigo-600",
            not @active && "bg-gray-700"
          ]}>
            <div class={[
              "absolute top-[2px] h-[14px] w-[14px] rounded-full bg-white transition-transform",
              @active && "translate-x-[16px]",
              not @active && "translate-x-[2px]"
            ]} />
          </div>
        </button>
      </div>

      <%!-- Inline config for write_gate_handler --%>
      <.write_gate_config
        :if={@active and @handler.id == "write_gate_handler"}
        allowed_writes={@handler.config["allowed_writes"] || []}
      />
    </div>
    """
  end

  attr :allowed_writes, :list, required: true

  defp write_gate_config(assigns) do
    ~H"""
    <div class="border-t border-gray-700/50 px-3 py-2.5 space-y-2">
      <label class="block text-[10px] font-medium text-gray-400 uppercase tracking-wider">Allowed Write Tools</label>
      <div class="flex gap-2">
        <input
          id="allowlist-input"
          type="text"
          placeholder="e.g. send_email, write_file"
          phx-keydown="add_allowed_write"
          phx-key="Enter"
          phx-hook="ClearOnEnter"
          class="flex-1 rounded border border-gray-700 bg-gray-900 px-2.5 py-1 text-xs text-white placeholder-gray-600 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
        />
      </div>
      <%= if @allowed_writes != [] do %>
        <div class="flex flex-wrap gap-1.5">
          <span
            :for={tool <- @allowed_writes}
            class="inline-flex items-center gap-1 rounded bg-indigo-600/10 border border-indigo-500/20 px-2 py-0.5 text-[10px] text-indigo-300"
          >
            <code class="font-mono">{tool}</code>
            <button
              type="button"
              phx-click="remove_allowed_write"
              phx-value-tool={tool}
              class="text-indigo-400/50 hover:text-red-400 transition-colors"
              aria-label={"Remove #{tool}"}
            >
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5">
                <path d="M5.28 4.22a.75.75 0 0 0-1.06 1.06L6.94 8l-2.72 2.72a.75.75 0 1 0 1.06 1.06L8 9.06l2.72 2.72a.75.75 0 1 0 1.06-1.06L9.06 8l2.72-2.72a.75.75 0 0 0-1.06-1.06L8 6.94 5.28 4.22Z" />
              </svg>
            </button>
          </span>
        </div>
      <% else %>
        <p class="text-[10px] text-gray-600 italic">No write tools allowed — all writes will be blocked.</p>
      <% end %>
    </div>
    """
  end

  defp short_name("permission_handler"), do: "Permission"
  defp short_name("write_gate_handler"), do: "WriteGate"
  defp short_name("log_handler"), do: "Log"
  defp short_name(other), do: other
end
