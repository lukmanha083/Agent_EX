defmodule AgentExWeb.AgentComponents do
  @moduledoc """
  Components for the Agent Builder — agent cards and editor forms.
  Uses CoreComponents for all form inputs (consistent dark-theme styling).
  SaladUI only for structural components (Dialog, Badge).
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]
  import AgentExWeb.InterventionComponents
  import SaladUI.Button

  @doc "Renders a grid of agent cards with a 'New Agent' button."
  attr :agents, :list, required: true

  def agent_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <button
        type="button"
        phx-click="new_agent"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-gray-700 p-6 text-gray-400 hover:border-indigo-500 hover:text-indigo-400 transition-colors min-h-[160px]"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-8 h-8">
          <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
        </svg>
        <span class="text-sm font-medium">New Agent</span>
      </button>

      <.agent_card :for={agent <- @agents} agent={agent} />
    </div>
    """
  end

  @doc "Renders a single agent card."
  attr :agent, :map, required: true

  def agent_card(assigns) do
    ~H"""
    <div class="group relative flex flex-col rounded-lg border border-gray-800 bg-gray-900 p-4 hover:border-gray-700 transition-colors min-h-[160px]">
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
        <div class="flex gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click="edit_agent"
            phx-value-id={@agent.id}
            class="p-1.5 rounded-md text-gray-400 hover:text-white hover:bg-gray-800 transition-colors"
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
            class="p-1.5 rounded-md text-gray-400 hover:text-red-400 hover:bg-gray-800 transition-colors"
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
          {length(@agent.tool_ids)} tools
        </.badge>
        <.badge :if={@agent.intervention_pipeline != []} variant="outline" class="text-[10px]">
          {length(@agent.intervention_pipeline)} handlers
        </.badge>
        <.badge :if={sandbox_configured?(@agent)} variant="outline" class="text-[10px] text-amber-400 border-amber-500/30">
          sandboxed
        </.badge>
      </div>
    </div>
    """
  end

  @doc "Renders the agent editor dialog."
  attr :agent, :map, default: nil
  attr :form, :map, required: true
  attr :show, :boolean, default: false
  attr :provider_options, :list, required: true
  attr :model_options, :list, required: true
  attr :intervention_pipeline, :list, default: []
  attr :sandbox, :map, default: %{}
  attr :project_root_path, :string, default: nil

  def agent_editor_dialog(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true">
      <!-- Backdrop -->
      <div class="fixed inset-0 bg-black/60" phx-click="close_editor"></div>
      <!-- Panel -->
      <div class="relative z-10 w-full max-w-lg mx-4 max-h-[90vh] rounded-lg border border-gray-800 bg-gray-900 shadow-xl flex flex-col">
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
              <div class="grid grid-cols-2 gap-3 mt-3">
                <.input type="select" name="provider" value={@form["provider"]} label="Provider" options={@provider_options} />
                <.input type="select" name="model" value={@form["model"]} label="Model" options={@model_options} />
              </div>
            </fieldset>

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

  defp sandbox_configured?(%{sandbox: sandbox}) when is_map(sandbox) do
    (sandbox["root_path"] || "") != "" or (sandbox["disallowed_commands"] || []) != []
  end

  defp sandbox_configured?(_), do: false
end
