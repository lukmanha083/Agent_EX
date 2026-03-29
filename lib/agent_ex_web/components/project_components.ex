defmodule AgentExWeb.ProjectComponents do
  @moduledoc """
  Components for project management — project cards, editor form, and sidebar switcher.
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]
  import SaladUI.Button

  @doc "Renders a grid of project cards with a 'New Project' button."
  attr(:projects, :list, required: true)

  def project_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <button
        type="button"
        phx-click="new_project"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-gray-700 p-6 text-gray-400 hover:border-indigo-500 hover:text-indigo-400 transition-colors min-h-[140px]"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-8 h-8">
          <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
        </svg>
        <span class="text-sm font-medium">New Project</span>
      </button>

      <.project_card :for={project <- @projects} project={project} />
    </div>
    """
  end

  @doc "Renders a single project card."
  attr(:project, :map, required: true)

  def project_card(assigns) do
    ~H"""
    <div class="group relative flex flex-col rounded-lg border border-gray-800 bg-gray-900 p-4 hover:border-gray-700 transition-colors min-h-[140px]">
      <div class="flex items-start justify-between mb-2">
        <div class="flex items-center gap-2">
          <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-indigo-600/20 text-indigo-400">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
              <path d="M3.75 3A1.75 1.75 0 0 0 2 4.75v3.26a3.235 3.235 0 0 1 1.75-.51h12.5c.644 0 1.245.188 1.75.51V6.75A1.75 1.75 0 0 0 16.25 5h-4.836a.25.25 0 0 1-.177-.073L9.823 3.513A1.75 1.75 0 0 0 8.586 3H3.75ZM3.75 9A1.75 1.75 0 0 0 2 10.75v4.5c0 .966.784 1.75 1.75 1.75h12.5A1.75 1.75 0 0 0 18 15.25v-4.5A1.75 1.75 0 0 0 16.25 9H3.75Z" />
            </svg>
          </div>
          <div>
            <h3 class="text-sm font-semibold text-white">{@project.name}</h3>
            <p :if={@project.root_path && @project.root_path != ""} class="text-[10px] text-gray-500 font-mono truncate max-w-[180px]">{@project.root_path}</p>
          </div>
        </div>
        <div :if={not @project.is_default} class="flex gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click="edit_project"
            phx-value-id={@project.id}
            class="p-1.5 rounded-md text-gray-400 hover:text-white hover:bg-gray-800 transition-colors"
            aria-label="Edit project"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
              <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
              <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.5A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
            </svg>
          </button>
          <button
            type="button"
            phx-click="delete_project"
            phx-value-id={@project.id}
            data-confirm="Delete this project and all its agents, conversations, and memory?"
            class="p-1.5 rounded-md text-gray-400 hover:text-red-400 hover:bg-gray-800 transition-colors"
            aria-label="Delete project"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
              <path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>
      </div>

      <p :if={@project.description} class="text-xs text-gray-400 mb-3 line-clamp-2">{@project.description}</p>

      <div class="mt-auto flex items-center gap-2">
        <.badge :if={@project.is_default} variant="secondary" class="text-[10px]">
          default
        </.badge>
      </div>
    </div>
    """
  end

  @doc "Renders the project editor dialog."
  attr(:project, :map, default: nil)
  attr(:form, :map, required: true)
  attr(:show, :boolean, default: false)

  def project_editor_dialog(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true">
      <div class="fixed inset-0 bg-black/60" phx-click="close_editor"></div>
      <div class="relative z-10 w-full max-w-md mx-4 rounded-lg border border-gray-800 bg-gray-900 p-6 shadow-xl">
        <div class="mb-4">
          <h2 class="text-lg font-semibold text-white">
            {if @project, do: "Edit Project", else: "New Project"}
          </h2>
          <p class="text-sm text-gray-400 mt-1">
            Projects group agents, conversations, tools, and memory into isolated workspaces.
          </p>
        </div>

        <.form for={@form} phx-submit="save_project" class="space-y-4">
          <.input type="text" name="name" value={@form["name"]} label="Name" placeholder="e.g. Stock Research" required />
          <.input type="text" name="description" value={@form["description"]} label="Description" placeholder="What this project is for" />
          <.input type="text" name="root_path" value={@form["root_path"]} label="Sandbox Root Path" placeholder="e.g. ~/projects/trading" />
          <p class="text-[10px] text-gray-500 -mt-2">
            Agents in this project will be confined to this directory.
          </p>

          <div class="flex justify-end gap-2 pt-2">
            <.button type="button" variant="outline" phx-click="close_editor" class="border-gray-700 text-gray-300 hover:bg-gray-800">
              Cancel
            </.button>
            <.button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white">
              {if @project, do: "Save Changes", else: "Create Project"}
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  @doc "Sidebar project switcher — only shown when user has multiple projects."
  attr(:projects, :list, required: true)
  attr(:current_project, :map, required: true)

  def project_switcher(assigns) do
    ~H"""
    <div :if={length(@projects) > 1} class="px-3 py-2 border-b border-gray-800">
      <label class="px-2 mb-1 block text-[10px] font-medium text-gray-500 uppercase tracking-wider">Project</label>
      <form phx-change="switch_project">
        <select
          name="project_id"
          class="w-full rounded-md border border-gray-700 bg-gray-800 px-2 py-1.5 text-xs text-white focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
        >
          <option
            :for={project <- @projects}
            value={project.id}
            selected={project.id == @current_project.id}
          >
            {project.name}
          </option>
        </select>
      </form>
    </div>
    """
  end
end
