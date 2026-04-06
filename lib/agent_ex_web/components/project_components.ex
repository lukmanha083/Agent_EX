defmodule AgentExWeb.ProjectComponents do
  @moduledoc """
  Components for project management — project cards, editor form, and sidebar switcher.
  """

  use AgentExWeb, :html

  @doc "Renders a grid of project cards with a 'New Project' button."
  attr(:projects, :list, required: true)

  def project_grid(assigns) do
    ~H"""
    <div data-testid="project-grid" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <button
        type="button"
        phx-click="new_project"
        data-testid="new-project-btn"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-gray-700 p-6 text-gray-400 hover:border-indigo-500 hover:text-indigo-400 transition-colors min-h-[140px]"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-8 h-8">
          <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
        </svg>
        <span class="text-sm font-medium">New Project</span>
      </button>

      <.project_card :for={project <- @projects} project={project} available={AgentEx.Projects.project_available?(project)} />
    </div>
    """
  end

  @doc "Renders a single project card."
  attr(:project, :map, required: true)
  attr(:available, :boolean, default: true)

  def project_card(assigns) do
    ~H"""
    <div data-testid={"project-card-#{@project.id}"} class={"group relative flex flex-col rounded-lg border p-4 transition-colors min-h-[140px] #{if @available, do: "border-gray-800 bg-gray-900 hover:border-gray-700", else: "border-amber-900/50 bg-gray-900/60 opacity-60"}"}>
      <div class="flex items-start justify-between mb-2">
        <div class="flex items-center gap-2">
          <div class={"flex h-8 w-8 items-center justify-center rounded-lg #{if @available, do: "bg-indigo-600/20 text-indigo-400", else: "bg-amber-600/20 text-amber-400"}"}>
            <svg :if={@available} xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
              <path d="M3.75 3A1.75 1.75 0 0 0 2 4.75v3.26a3.235 3.235 0 0 1 1.75-.51h12.5c.644 0 1.245.188 1.75.51V6.75A1.75 1.75 0 0 0 16.25 5h-4.836a.25.25 0 0 1-.177-.073L9.823 3.513A1.75 1.75 0 0 0 8.586 3H3.75ZM3.75 9A1.75 1.75 0 0 0 2 10.75v4.5c0 .966.784 1.75 1.75 1.75h12.5A1.75 1.75 0 0 0 18 15.25v-4.5A1.75 1.75 0 0 0 16.25 9H3.75Z" />
            </svg>
            <svg :if={!@available} xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
              <path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495ZM10 5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 5Zm0 9a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z" clip-rule="evenodd" />
            </svg>
          </div>
          <div>
            <h3 class="text-sm font-semibold text-white">{@project.name}</h3>
            <p :if={@project.root_path && @project.root_path != ""} class="text-[10px] text-gray-500 font-mono truncate max-w-[180px]">{@project.root_path}</p>
            <p :if={!@available} class="text-[10px] text-amber-400 font-medium">Unavailable on this machine</p>
          </div>
        </div>
        <div class="flex gap-1 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 focus-within:opacity-100 transition-opacity">
          <button
            type="button"
            phx-click="delete_project"
            phx-value-id={@project.id}
            data-confirm="Delete this project and all its agents, conversations, and memory?"
            class="p-1.5 rounded-md text-gray-400 hover:text-red-400 hover:bg-gray-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500 transition-colors"
            aria-label="Delete project"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
              <path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>
      </div>

      <p :if={@project.description && String.trim(@project.description) != ""} class="text-xs text-gray-400 mb-3 line-clamp-2">{@project.description}</p>

      <div class="mt-auto flex items-center gap-2 flex-wrap">
        <.badge :if={@project.provider} variant="outline" class="text-[10px] text-indigo-400 border-indigo-500/30">
          {@project.provider}
        </.badge>
        <.badge :if={@project.model} variant="secondary" class="text-[10px]">
          {@project.model}
        </.badge>
      </div>
    </div>
    """
  end
end
