defmodule AgentExWeb.AgentComponents do
  @moduledoc """
  Components for the Agent Builder — agent cards and editor forms.
  Uses CoreComponents for all form inputs (consistent dark-theme styling).
  SaladUI only for structural components (Dialog, Badge).
  """

  use AgentExWeb, :html

  alias AgentEx.ProviderTools

  import AgentExWeb.CoreComponents, except: [button: 1]
  import AgentExWeb.InterventionComponents
  import SaladUI.Button

  @doc "Renders a grid of agent cards with a 'New Agent' button."
  attr(:agents, :list, required: true)
  attr(:project_root_path, :string, default: nil)

  def agent_grid(assigns) do
    ~H"""
    <div data-testid="agent-grid" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <button
        type="button"
        phx-click="new_agent"
        data-testid="new-agent-btn"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-gray-700 p-6 text-gray-400 hover:border-indigo-500 hover:text-indigo-400 transition-colors min-h-[160px]"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-8 h-8">
          <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
        </svg>
        <span class="text-sm font-medium">New Agent</span>
      </button>

      <button
        type="button"
        phx-click="show_import"
        data-testid="import-agent-btn"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-gray-700 p-6 text-gray-400 hover:border-emerald-500 hover:text-emerald-400 transition-colors min-h-[160px]"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-8 h-8">
          <path d="M9.25 13.25a.75.75 0 0 0 1.5 0V4.636l2.955 3.129a.75.75 0 0 0 1.09-1.03l-4.25-4.5a.75.75 0 0 0-1.09 0l-4.25 4.5a.75.75 0 1 0 1.09 1.03L9.25 4.636v8.614Z" />
          <path d="M3.5 12.75a.75.75 0 0 0-1.5 0v2.5A2.75 2.75 0 0 0 4.75 18h10.5A2.75 2.75 0 0 0 18 15.25v-2.5a.75.75 0 0 0-1.5 0v2.5c0 .69-.56 1.25-1.25 1.25H4.75c-.69 0-1.25-.56-1.25-1.25v-2.5Z" />
        </svg>
        <span class="text-sm font-medium">Import JSON</span>
      </button>

      <.agent_card :for={agent <- @agents} agent={agent} project_root_path={@project_root_path} />
    </div>
    """
  end

  @doc "Renders a single agent card."
  attr(:agent, :map, required: true)
  attr(:project_root_path, :string, default: nil)

  def agent_card(assigns) do
    ~H"""
    <div data-testid={"agent-card-#{@agent.id}"} class="group relative flex flex-col rounded-lg border border-gray-800 bg-gray-900 p-4 hover:border-gray-700 transition-colors min-h-[160px]">
      <div class="flex items-start justify-between mb-3">
        <div class="flex items-center gap-2">
          <div class="flex h-8 w-8 items-center justify-center rounded-full bg-indigo-600/20 text-indigo-400">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
              <path d="M10 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM3.465 14.493a1.23 1.23 0 0 0 .41 1.412A9.957 9.957 0 0 0 10 18c2.31 0 4.438-.784 6.131-2.1.43-.333.604-.903.408-1.41a7.002 7.002 0 0 0-13.074.003Z" />
            </svg>
          </div>
          <div>
            <h3 class="text-sm font-semibold text-white">{@agent.name}</h3>
            <p :if={@agent.role} class="text-[10px] text-indigo-400 truncate max-w-[150px]">{@agent.role}</p>
            <p class="text-[10px] text-gray-500">{@agent.provider}/{@agent.model}</p>
          </div>
        </div>
        <div class="flex gap-1 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 focus-within:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click="edit_agent"
            phx-value-id={@agent.id}
            class="p-1.5 rounded-md text-gray-400 hover:text-white hover:bg-gray-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 transition-colors"
            aria-label="Edit agent"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
              <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
              <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.5A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
            </svg>
          </button>
          <button
            type="button"
            phx-click="delete_agent"
            phx-value-id={@agent.id}
            data-confirm="Delete this agent?"
            class="p-1.5 rounded-md text-gray-400 hover:text-red-400 hover:bg-gray-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500 transition-colors"
            aria-label="Delete agent"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
              <path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>
      </div>

      <p :if={@agent.description} class="text-xs text-gray-400 mb-3 line-clamp-2">{@agent.description}</p>

      <div class="mt-auto flex items-center gap-2 flex-wrap">
        <.badge variant="secondary" class="text-[10px]">
          {if (@agent.tool_ids || []) == [], do: "all tools", else: "#{length(@agent.tool_ids)} tools"}
        </.badge>
        <.badge :if={(@agent.intervention_pipeline || []) != []} variant="outline" class="text-[10px]">
          {length(@agent.intervention_pipeline || [])} handlers
        </.badge>
        <.badge :if={has_enabled_builtins?(@agent)} variant="outline" class="text-[10px] text-cyan-400 border-cyan-500/30">
          {enabled_builtin_count(@agent)} builtins
        </.badge>
        <.badge :if={sandbox_configured?(@agent, @project_root_path)} variant="outline" class="text-[10px] text-amber-400 border-amber-500/30">
          sandboxed
        </.badge>
      </div>
    </div>
    """
  end

  @doc "Renders the agent editor dialog."
  attr(:agent, :map, default: nil)
  attr(:form, :map, required: true)
  attr(:show, :boolean, default: false)
  attr(:provider_options, :list, required: true)
  attr(:model_options, :list, required: true)
  attr(:context_window_display, :string, default: nil)
  attr(:intervention_pipeline, :list, default: [])
  attr(:sandbox, :map, default: %{})
  attr(:project_root_path, :string, default: nil)
  attr(:disabled_builtins, :list, default: [])

  def agent_editor_dialog(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true" phx-window-keydown="close_editor" phx-key="Escape">
      <!-- Backdrop -->
      <div class="fixed inset-0 bg-black/60" phx-click="close_editor"></div>
      <!-- Panel -->
      <div data-testid="agent-editor" class="relative z-10 w-full max-w-lg mx-4 max-h-[90vh] rounded-lg border border-gray-800 bg-gray-900 shadow-xl flex flex-col">
        <div class="p-6 pb-0 shrink-0">
          <h2 class="text-lg font-semibold text-white">
            {if @agent, do: "Edit Agent", else: "New Agent"}
          </h2>
          <p class="text-sm text-gray-400 mt-1">
            Configure agent identity, safety boundaries, and intervention pipeline.
          </p>
        </div>

        <.form for={@form} phx-submit="save_agent" phx-change="validate_agent" class="flex flex-col flex-1 min-h-0">
          <div class="flex-1 overflow-y-auto p-6 space-y-4">
            <input :if={@agent} type="hidden" name="agent_id" value={@agent.id} />

            <%!-- Section: Identity --%>
            <fieldset class="space-y-3">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Identity</legend>
              <.input type="text" name="name" value={@form["name"]} label="Name" placeholder="e.g. Security Auditor" required />
              <.input type="text" name="role" value={@form["role"]} label="Role" placeholder="e.g. Senior security auditor specializing in web applications" />
              <.input type="text" name="expertise" value={@form["expertise"]} label="Expertise" placeholder="e.g. OWASP Top 10, secure code review, threat modeling (comma-separated)" />
              <.input type="text" name="personality" value={@form["personality"]} label="Communication Style" placeholder="e.g. methodical, cites evidence, errs on the side of caution" />
              <.input type="text" name="description" value={@form["description"]} label="Description" placeholder="Brief summary shown on agent card" />
            </fieldset>

            <%!-- Section: Goal --%>
            <fieldset class="space-y-3 border-t border-gray-800 pt-4">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Goal</legend>
              <.input type="textarea" name="goal" value={@form["goal"]} label="Primary Goal" placeholder="e.g. Identify security vulnerabilities in code changes before they reach production" class="min-h-[60px]" />
              <.input type="text" name="success_criteria" value={@form["success_criteria"]} label="Success Criteria" placeholder="e.g. All critical findings have remediation steps, zero false negatives on OWASP Top 10" />
            </fieldset>

            <%!-- Section: Constraints --%>
            <fieldset class="space-y-3 border-t border-gray-800 pt-4">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Constraints</legend>
              <.input type="textarea" name="constraints" value={@form["constraints"]} label="Constraints" placeholder="e.g. Never execute code directly — only analyze and report&#10;Flag uncertainty explicitly rather than guessing (one per line)" class="min-h-[60px]" />
              <.input type="text" name="scope" value={@form["scope"]} label="Scope" placeholder="e.g. Only review files changed in the current PR" />
            </fieldset>

            <%!-- Section: Tool Guidance --%>
            <fieldset class="space-y-3 border-t border-gray-800 pt-4">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Tool Guidance</legend>
              <.input type="textarea" name="tool_guidance" value={@form["tool_guidance"]} label="Tool Usage Instructions" placeholder="e.g. Always use search_code before read_file to find relevant files.&#10;Run tests after any code change.&#10;Use save_memory to record important findings." class="min-h-[60px]" />
            </fieldset>

            <%!-- Section: Output Format --%>
            <fieldset class="space-y-3 border-t border-gray-800 pt-4">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Output Format</legend>
              <.input type="textarea" name="output_format" value={@form["output_format"]} label="Response Template" placeholder="e.g. ## Findings&#10;...&#10;## Severity&#10;...&#10;## Remediation&#10;..." class="min-h-[60px]" />
            </fieldset>

            <%!-- Section: Additional Instructions --%>
            <fieldset class="space-y-3 border-t border-gray-800 pt-4">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Additional Instructions</legend>
              <.input type="textarea" name="system_prompt" value={@form["system_prompt"]} label="System Prompt" placeholder="Any additional free-form instructions not covered above" class="min-h-[60px]" />
            </fieldset>

            <%!-- Section: Provider/Model --%>
            <fieldset class="border-t border-gray-800 pt-4">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Model</legend>
              <%= if @agent do %>
                <%!-- Locked after creation --%>
                <input type="hidden" name="provider" value={@form["provider"]} />
                <input type="hidden" name="model" value={@form["model"]} />
                <div class="grid grid-cols-2 gap-3 mt-3">
                  <div>
                    <label class="block text-sm font-medium text-gray-300 mb-1">Provider</label>
                    <div class="flex items-center gap-2 rounded-lg bg-gray-800/50 border border-gray-700 px-3 py-2 text-sm text-gray-400">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 text-gray-500 shrink-0">
                        <path fill-rule="evenodd" d="M8 1a3.5 3.5 0 0 0-3.5 3.5V7A1.5 1.5 0 0 0 3 8.5v5A1.5 1.5 0 0 0 4.5 15h7a1.5 1.5 0 0 0 1.5-1.5v-5A1.5 1.5 0 0 0 11.5 7V4.5A3.5 3.5 0 0 0 8 1Zm2 6V4.5a2 2 0 1 0-4 0V7h4Z" clip-rule="evenodd" />
                      </svg>
                      {@form["provider"]}
                    </div>
                  </div>
                  <div>
                    <label class="block text-sm font-medium text-gray-300 mb-1">Model</label>
                    <div class="flex items-center gap-2 rounded-lg bg-gray-800/50 border border-gray-700 px-3 py-2 text-sm text-gray-400">
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 text-gray-500 shrink-0">
                        <path fill-rule="evenodd" d="M8 1a3.5 3.5 0 0 0-3.5 3.5V7A1.5 1.5 0 0 0 3 8.5v5A1.5 1.5 0 0 0 4.5 15h7a1.5 1.5 0 0 0 1.5-1.5v-5A1.5 1.5 0 0 0 11.5 7V4.5A3.5 3.5 0 0 0 8 1Zm2 6V4.5a2 2 0 1 0-4 0V7h4Z" clip-rule="evenodd" />
                      </svg>
                      {@form["model"]}
                    </div>
                  </div>
                </div>
                <p class="text-[10px] text-gray-500 mt-2">Provider and model are locked after creation.</p>
              <% else %>
                <div class="grid grid-cols-2 gap-3 mt-3">
                  <.input type="select" name="provider" value={@form["provider"]} label="Provider" options={@provider_options} />
                  <.input type="select" name="model" value={@form["model"]} label="Model" options={@model_options} />
                </div>
              <% end %>
              <div :if={@context_window_display} class="flex items-center gap-2 rounded-md bg-gray-800/50 border border-gray-700 px-3 py-2 mt-3">
                <span class="text-xs text-gray-400">Context window:</span>
                <span class="text-xs font-mono text-white">{@context_window_display}</span>
                <span class="text-xs text-gray-500">tokens</span>
              </div>
            </fieldset>

            <%!-- Section: Provider Built-in Tools --%>
            <.builtin_tools_section
              provider={@form["provider"] || "openai"}
              disabled_builtins={@disabled_builtins}
            />

            <%!-- Sandbox boundary section --%>
            <div class="border-t border-gray-800 pt-4">
              <.sandbox_section sandbox={@sandbox} project_root_path={@project_root_path} />
            </div>

            <%!-- Intervention pipeline section --%>
            <div class="border-t border-gray-800 pt-4">
              <.intervention_section pipeline={@intervention_pipeline} />
            </div>
          </div>

          <div class="flex justify-end gap-2 p-6 pt-4 border-t border-gray-800 shrink-0">
            <.button type="button" variant="outline" phx-click="close_editor" class="border-gray-700 text-gray-300 hover:bg-gray-800">
              Cancel
            </.button>
            <.button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white">
              {if @agent, do: "Save Changes", else: "Create Agent"}
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr(:provider, :string, required: true)
  attr(:disabled_builtins, :list, default: [])

  defp builtin_tools_section(assigns) do
    builtins = ProviderTools.list(assigns.provider)
    assigns = assign(assigns, :builtins, builtins)

    ~H"""
    <div :if={@builtins != []} class="border-t border-gray-800 pt-4">
      <fieldset class="space-y-3">
        <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">Provider Tools</legend>
        <p class="text-xs text-gray-400">
          Built-in tools provided by the API. Enabled by default — toggle off to disable.
        </p>
        <div class="space-y-2">
          <div :for={spec <- @builtins} class="flex items-center justify-between rounded-md border border-gray-800 bg-gray-800/50 px-3 py-2">
            <div>
              <span class="text-sm font-medium text-white">{spec.name}</span>
              <p class="text-xs text-gray-400">{spec.description}</p>
            </div>
            <button
              type="button"
              phx-click={toggle_event(spec.name, @disabled_builtins)}
              phx-value-name={spec.name}
              class="relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500"
              style={toggle_bg(spec.name, @disabled_builtins)}
              role="switch"
              aria-checked={to_string(spec.name not in @disabled_builtins)}
              aria-label={"Toggle #{spec.name}"}
            >
              <span
                class="pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition-transform"
                style={toggle_knob(spec.name, @disabled_builtins)}
              />
            </button>
          </div>
        </div>
      </fieldset>
    </div>
    """
  end

  defp toggle_event(name, disabled_builtins) do
    if name in disabled_builtins, do: "enable_builtin", else: "disable_builtin"
  end

  defp toggle_bg(name, disabled_builtins) do
    if name in disabled_builtins,
      do: "background-color: rgb(55, 65, 81)",
      else: "background-color: rgb(79, 70, 229)"
  end

  defp toggle_knob(name, disabled_builtins) do
    if name in disabled_builtins,
      do: "transform: translateX(0)",
      else: "transform: translateX(1rem)"
  end

  defp has_enabled_builtins?(agent) do
    enabled_builtin_count(agent) > 0
  end

  defp enabled_builtin_count(agent) do
    total = length(ProviderTools.list(agent.provider || "openai"))
    disabled = length(agent.disabled_builtins || [])
    max(total - disabled, 0)
  end

  defp sandbox_configured?(%{sandbox: sandbox}, project_root_path) when is_map(sandbox) do
    (project_root_path || "") != "" or
      (sandbox["root_path"] || "") != "" or
      (sandbox["disallowed_commands"] || []) != []
  end

  defp sandbox_configured?(_, _), do: false

  @doc "Renders a dialog for importing an agent config from JSON."
  attr(:show, :boolean, default: false)

  def import_agent_dialog(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true" phx-window-keydown="close_import" phx-key="Escape">
      <div class="fixed inset-0 bg-black/60" phx-click="close_import"></div>
      <div class="relative z-10 w-full max-w-lg mx-4 max-h-[90vh] rounded-lg border border-gray-800 bg-gray-900 shadow-xl flex flex-col">
        <div class="p-6 pb-0 shrink-0">
          <h2 class="text-lg font-semibold text-white">Import Agent from JSON</h2>
          <p class="text-sm text-gray-400 mt-1">
            Paste the JSON output from <code class="text-emerald-400">kidkazz distill generate</code>
          </p>
        </div>
        <form phx-submit="import_agent" class="flex flex-col flex-1 overflow-hidden">
          <div class="flex-1 overflow-y-auto p-6 space-y-4">
            <textarea
              name="json_content"
              rows="16"
              maxlength="65536"
              placeholder='{"name": "...", "role": "...", ...}'
              class="w-full rounded-md border border-gray-700 bg-gray-800 px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500 font-mono"
              required
            ></textarea>
          </div>
          <div class="flex justify-end gap-3 p-6 pt-0 shrink-0">
            <button type="button" phx-click="close_import" class="rounded-md px-4 py-2 text-sm text-gray-400 hover:text-white transition-colors">
              Cancel
            </button>
            <button type="submit" class="rounded-md bg-emerald-600 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-500 transition-colors">
              Import
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
