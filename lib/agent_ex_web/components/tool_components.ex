defmodule AgentExWeb.ToolComponents do
  @moduledoc """
  Components for the unified tool manager — tool source tabs,
  tool cards, MCP connect form, and plugin browser.
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]
  import AgentExWeb.HttpToolComponents
  import SaladUI.Button
  import SaladUI.Tabs

  # --- Tool source tabs ---

  @doc "Renders the tabbed tool management panel."
  attr(:active_tab, :string, default: "builtin")
  attr(:builtin_plugins, :list, default: [])
  attr(:available_plugins, :list, default: [])
  attr(:mcp_servers, :list, default: [])
  attr(:attached_sources, :any, default: nil)
  attr(:http_tools, :list, default: [])
  attr(:builtin_mcp_servers, :list, default: [])
  attr(:show_builtin_mcp_editor, :boolean, default: false)
  attr(:builtin_mcp_editing, :any, default: nil)
  attr(:builtin_mcp_form, :map, default: %{})

  def tool_tabs(assigns) do
    ~H"""
    <.tabs id="tool-tabs" default={@active_tab} class="w-full">
      <.tabs_list class="bg-gray-800/50 border border-gray-700 mb-4">
        <.tabs_trigger value="builtin" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          Built-in
        </.tabs_trigger>
        <.tabs_trigger value="http" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          HTTP API
        </.tabs_trigger>
        <.tabs_trigger value="plugins" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          Plugins
        </.tabs_trigger>
        <.tabs_trigger value="mcp" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          MCP (Client)
        </.tabs_trigger>
        <.tabs_trigger value="builtin_mcp" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          MCP (Built-in)
        </.tabs_trigger>
      </.tabs_list>

      <.tabs_content value="builtin">
        <.builtin_tools_panel plugins={@builtin_plugins} />
      </.tabs_content>

      <.tabs_content value="http">
        <.http_tool_grid tools={@http_tools} />
      </.tabs_content>

      <.tabs_content value="plugins">
        <.plugin_browser plugins={@available_plugins} attached_sources={@attached_sources} />
      </.tabs_content>

      <.tabs_content value="mcp">
        <.mcp_panel servers={@mcp_servers} />
      </.tabs_content>

      <.tabs_content value="builtin_mcp">
        <.builtin_mcp_panel
          servers={@builtin_mcp_servers}
          show_editor={@show_builtin_mcp_editor}
          editing={@builtin_mcp_editing}
          form={@builtin_mcp_form}
        />
      </.tabs_content>

    </.tabs>
    """
  end

  # --- Built-in tools (FileSystem, ShellExec) ---

  attr(:plugins, :list, default: [])

  defp builtin_tools_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-gray-400 mb-4">
        Built-in tool plugins that ship with AgentEx. These are always available to specialist agents.
      </p>
      <%= if @plugins == [] do %>
        <.empty_state icon="wrench" message="No built-in plugins" />
      <% else %>
        <.builtin_source_card
          :for={plugin <- @plugins}
          name={plugin.name}
          description={plugin.description}
          version={plugin.version}
          tool_count={length(plugin.tool_names)}
          tool_names={plugin.tool_names}
        />
      <% end %>
    </div>
    """
  end

  # --- Plugin browser ---

  attr(:plugins, :list, default: [])
  attr(:attached_sources, :any, default: nil)

  defp plugin_browser(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between mb-4">
        <p class="text-sm text-gray-400">
          User-installable tool plugins with custom configuration.
          Unlike built-in plugins, these can be attached/detached per project.
        </p>
      </div>
      <%= if @plugins == [] do %>
        <.empty_state icon="puzzle" message="No user plugins installed yet. Plugin marketplace coming soon." />
      <% else %>
        <.tool_source_card
          :for={plugin <- @plugins}
          name={plugin.name}
          description={plugin.description}
          version={plugin.version}
          tool_count={length(plugin[:tool_names] || [])}
          source="plugin"
          attached={@attached_sources && MapSet.member?(@attached_sources, {"plugin", plugin.name})}
        />
      <% end %>
    </div>
    """
  end

  # --- MCP servers ---

  attr(:servers, :list, default: [])

  defp mcp_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between mb-2">
        <p class="text-sm text-gray-400">Connect to MCP-compatible tool servers</p>
        <button
          type="button"
          phx-click="show_mcp_form"
          class="inline-flex items-center gap-1.5 rounded-md bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          Connect
        </button>
      </div>

      <%= if @servers == [] do %>
        <.empty_state icon="server" message="No MCP servers connected" />
      <% else %>
        <.tool_source_card
          :for={server <- @servers}
          name={server[:id] || server.name}
          display_name={server.name}
          description={"#{server.transport} transport"}
          version=""
          tool_count={server.tool_count}
          source="mcp"
          attached={server[:attached] != false}
        />
      <% end %>
    </div>
    """
  end

  # --- Built-in MCP (server-side) panel ---

  attr(:servers, :list, default: [])
  attr(:show_editor, :boolean, default: false)
  attr(:editing, :any, default: nil)
  attr(:form, :map, default: %{})

  defp builtin_mcp_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between mb-2">
        <div>
          <p class="text-sm text-gray-400">
            Server-side MCP servers for Anthropic models. Claude calls these directly during inference.
          </p>
          <p class="text-xs text-amber-400/80 mt-1">
            Anthropic models only — not available for other providers.
          </p>
        </div>
        <button
          type="button"
          phx-click="new_builtin_mcp"
          class="inline-flex items-center gap-1.5 rounded-md bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 transition-colors shrink-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          Add Server
        </button>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <div
          :for={server <- @servers}
          class="group relative flex flex-col rounded-lg border border-gray-800 bg-gray-900 p-4 hover:border-gray-700 transition-colors min-h-[140px]"
        >
          <div class="flex items-start justify-between mb-2">
            <div class="flex items-center gap-2 min-w-0">
              <div class="flex h-8 w-8 items-center justify-center rounded-full bg-emerald-600/20 text-emerald-400 shrink-0">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
                  <path d="M4.632 3.533A2 2 0 0 1 6.577 2h6.846a2 2 0 0 1 1.945 1.533l1.976 8.234A3.489 3.489 0 0 0 16 11.5H4c-.476 0-.93.095-1.344.267l1.976-8.234Z" />
                  <path fill-rule="evenodd" d="M4 13a2 2 0 1 0 0 4h12a2 2 0 1 0 0-4H4Zm11.24 2a.75.75 0 0 1 .75-.75H16a.75.75 0 0 1 .75.75v.01a.75.75 0 0 1-.75.75h-.01a.75.75 0 0 1-.75-.75V15Zm-2.25-.75a.75.75 0 0 0-.75.75v.01c0 .414.336.75.75.75H13a.75.75 0 0 0 .75-.75V15a.75.75 0 0 0-.75-.75h-.01Z" clip-rule="evenodd" />
                </svg>
              </div>
              <div class="min-w-0">
                <h3 class="text-sm font-semibold text-white truncate">{server.name}</h3>
                <p class="text-[10px] text-gray-500 truncate max-w-[180px]">{server.url}</p>
              </div>
            </div>
            <div :if={!server.system} class="flex gap-1 opacity-100 md:opacity-0 md:group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
              <button type="button" phx-click="edit_builtin_mcp" phx-value-id={server.id} class="p-1.5 rounded-md text-gray-400 hover:text-white hover:bg-gray-800 transition-colors" aria-label="Edit server">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
                  <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
                  <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.5A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
                </svg>
              </button>
              <button type="button" phx-click="delete_builtin_mcp" phx-value-id={server.id} data-confirm="Delete this MCP server?" class="p-1.5 rounded-md text-gray-400 hover:text-red-400 hover:bg-gray-800 transition-colors" aria-label="Delete server">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
                  <path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5Z" clip-rule="evenodd" />
                </svg>
              </button>
            </div>
          </div>

          <p :if={server.description} class="text-xs text-gray-400 mb-3 line-clamp-2">{server.description}</p>

          <div class="mt-auto flex items-center gap-2">
            <button
              type="button"
              phx-click={unless server.system, do: "toggle_builtin_mcp"}
              phx-value-id={server.id}
              disabled={server.system}
              class={"relative inline-flex h-5 w-9 shrink-0 rounded-full border-2 border-transparent transition-colors #{if server.system, do: "cursor-not-allowed opacity-50", else: "cursor-pointer"}"}
              style={if server.enabled, do: "background-color: rgb(79, 70, 229)", else: "background-color: rgb(55, 65, 81)"}
              role="switch"
              aria-checked={to_string(server.enabled)}
              aria-disabled={to_string(server.system)}
              aria-label={"Toggle #{server.name}"}
            >
              <span
                class="pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition-transform"
                style={if server.enabled, do: "transform: translateX(1rem)", else: "transform: translateX(0)"}
              />
            </button>
            <span class="text-[10px] text-gray-500">{if server.enabled, do: "enabled", else: "disabled"}</span>
            <.badge :if={server.system} variant="outline" class="text-[10px] text-cyan-400 border-cyan-500/30">system</.badge>
            <.badge variant="outline" class="ml-auto text-[10px]">{server.provider}</.badge>
          </div>
        </div>
      </div>

      <%!-- Editor dialog --%>
      <div :if={@show_editor} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true" aria-labelledby="builtin-mcp-editor-title" phx-window-keydown="close_builtin_mcp_editor" phx-key="Escape">
        <div class="fixed inset-0 bg-black/60" phx-click="close_builtin_mcp_editor"></div>
        <div class="relative z-10 w-full max-w-lg mx-4 rounded-lg border border-gray-800 bg-gray-900 shadow-xl">
          <div class="p-6 pb-0">
            <h2 id="builtin-mcp-editor-title" class="text-lg font-semibold text-white">
              {if @editing, do: "Edit MCP Server", else: "Add MCP Server"}
            </h2>
          </div>

          <.form for={@form} phx-submit="save_builtin_mcp" class="p-6 space-y-4">
            <input :if={@editing} type="hidden" name="server_id" value={@editing.id} />
            <.input type="text" name="name" value={@form["name"]} label="Name" placeholder="e.g. context7" required />
            <.input type="text" name="url" value={@form["url"]} label="URL (SSE endpoint)" placeholder="https://mcp.example.com/sse" required />
            <.input type="text" name="description" value={@form["description"]} label="Description" placeholder="What this server provides" />
            <input type="hidden" name="provider" value="anthropic" />
            <.input type="text" name="auth_token_key" value={@form["auth_token_key"]} label="Vault Key (for auth token)" placeholder="e.g. mcp:github" />
            <p class="text-[10px] text-gray-500 -mt-2">Store the token in Vault with this key. Leave blank for public servers.</p>

            <div class="flex justify-end gap-2 pt-2">
              <.button type="button" variant="outline" phx-click="close_builtin_mcp_editor" class="border-gray-700 text-gray-300">
                Cancel
              </.button>
              <.button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white">
                {if @editing, do: "Save", else: "Add Server"}
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # --- Shared components ---

  @doc "Renders a read-only built-in plugin card (no attach/detach)."
  attr(:name, :string, required: true)
  attr(:description, :string, default: "")
  attr(:version, :string, default: "")
  attr(:tool_count, :integer, default: 0)
  attr(:tool_names, :list, default: [])

  def builtin_source_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-gray-800 bg-gray-900 px-4 py-3">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="flex h-8 w-8 items-center justify-center rounded-md bg-emerald-600/20 text-emerald-400">
            <.source_icon source="built-in" />
          </div>
          <div>
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium text-white">{@name}</span>
              <span :if={@version != ""} class="text-[10px] text-gray-500">{@version}</span>
            </div>
            <p :if={@description != ""} class="text-xs text-gray-400">{@description}</p>
          </div>
        </div>
        <.badge variant="secondary" class="text-[10px]">{@tool_count} tools</.badge>
      </div>
      <div :if={@tool_names != []} class="mt-2 ml-11 flex flex-wrap gap-1.5">
        <span
          :for={tool_name <- @tool_names}
          class="inline-flex items-center rounded-md bg-gray-800 px-2 py-0.5 text-[10px] font-mono text-gray-400"
        >
          {tool_name}
        </span>
      </div>
    </div>
    """
  end

  @doc "Renders a tool source card (plugin, MCP server, etc.) with attach/detach."
  attr(:name, :string, required: true)
  attr(:display_name, :string, default: nil)
  attr(:description, :string, default: "")
  attr(:version, :string, default: "")
  attr(:tool_count, :integer, default: 0)
  attr(:source, :string, default: "plugin")
  attr(:attached, :boolean, default: false)

  def tool_source_card(assigns) do
    ~H"""
    <div class="flex items-center justify-between rounded-lg border border-gray-800 bg-gray-900 px-4 py-3 hover:border-gray-700 transition-colors">
      <div class="flex items-center gap-3">
        <div class={[
          "flex h-8 w-8 items-center justify-center rounded-md",
          source_color(@source)
        ]}>
          <.source_icon source={@source} />
        </div>
        <div>
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-white">{@display_name || @name}</span>
            <span :if={@version != ""} class="text-[10px] text-gray-500">{@version}</span>
          </div>
          <p :if={@description != ""} class="text-xs text-gray-400">{@description}</p>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <.badge variant="secondary" class="text-[10px]">{@tool_count} tools</.badge>
        <%= if @attached do %>
          <button
            type="button"
            phx-click="detach_source"
            phx-value-name={@name}
            phx-value-source={@source}
            class="text-xs text-red-400 hover:text-red-300 transition-colors"
          >
            Detach
          </button>
        <% else %>
          <button
            type="button"
            phx-click="attach_source"
            phx-value-name={@name}
            phx-value-source={@source}
            class="text-xs text-indigo-400 hover:text-indigo-300 transition-colors"
          >
            Attach
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc "Renders a single tool card."
  attr(:tool, :map, required: true)

  def tool_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-gray-800 bg-gray-900 p-3 hover:border-gray-700 transition-colors">
      <div class="flex items-start justify-between mb-2">
        <span class="text-sm font-medium text-white">{@tool.name}</span>
        <.badge variant={if @tool.kind == :write, do: "destructive", else: "secondary"} class="text-[10px]">
          {@tool.kind}
        </.badge>
      </div>
      <p :if={@tool.description} class="text-xs text-gray-400 line-clamp-2">{@tool.description}</p>
    </div>
    """
  end

  @doc "MCP connection dialog."
  attr(:show, :boolean, default: false)
  attr(:form, :map, default: %{})

  def mcp_connect_dialog(assigns) do
    ~H"""
    <div :if={@show} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true">
      <div class="fixed inset-0 bg-black/60" phx-click="close_mcp_form"></div>
      <div data-testid="mcp-dialog" class="relative z-10 w-full max-w-md mx-4 rounded-lg border border-gray-800 bg-gray-900 p-6 shadow-xl">
        <div class="mb-4">
          <h2 class="text-lg font-semibold text-white">Connect MCP Server</h2>
          <p class="text-sm text-gray-400 mt-1">Connect to an MCP-compatible tool server via stdio or HTTP.</p>
        </div>

        <.form for={@form} phx-submit="connect_mcp" class="space-y-4">
          <.input type="text" name="name" value={@form[:name]} label="Name" placeholder="e.g. sqlite-server" required />
          <.input type="select" name="transport" value={@form[:transport] || "stdio"} label="Transport" options={[{"stdio", "stdio"}, {"http", "HTTP"}]} />
          <.input type="text" name="command" value={@form[:command]} label="Command / URL" placeholder="npx @anthropic/mcp-server-sqlite" required />

          <div class="flex justify-end gap-2 pt-2">
            <.button type="button" variant="outline" phx-click="close_mcp_form" class="border-gray-700 text-gray-300 hover:bg-gray-800">
              Cancel
            </.button>
            <.button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white">
              Connect
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp source_color("built-in"), do: "bg-emerald-600/20 text-emerald-400"
  defp source_color("plugin"), do: "bg-purple-600/20 text-purple-400"
  defp source_color("mcp"), do: "bg-blue-600/20 text-blue-400"
  defp source_color("custom"), do: "bg-amber-600/20 text-amber-400"
  defp source_color(_), do: "bg-gray-600/20 text-gray-400"

  defp source_icon(%{source: "built-in"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
      <path fill-rule="evenodd" d="M11.5 8a3.5 3.5 0 0 0-7 0 3.5 3.5 0 0 0 7 0ZM8 3a5 5 0 1 0 0 10A5 5 0 0 0 8 3Z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp source_icon(%{source: "plugin"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
      <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2a1.5 1.5 0 0 1 1.5 1.5V5h1A1.5 1.5 0 0 1 13 6.5v2A1.5 1.5 0 0 1 11.5 10H10v1.5A1.5 1.5 0 0 1 8.5 13h-2A1.5 1.5 0 0 1 5 11.5V10H3.5A1.5 1.5 0 0 1 2 8.5v-2A1.5 1.5 0 0 1 3.5 5H5V3.5Z" />
    </svg>
    """
  end

  defp source_icon(%{source: "mcp"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
      <path d="M3.5 2A1.5 1.5 0 0 0 2 3.5v9A1.5 1.5 0 0 0 3.5 14h9a1.5 1.5 0 0 0 1.5-1.5v-9A1.5 1.5 0 0 0 12.5 2h-9ZM5 5.75a.75.75 0 1 1 1.5 0 .75.75 0 0 1-1.5 0Zm4 0a.75.75 0 1 1 1.5 0 .75.75 0 0 1-1.5 0ZM6.75 9.25a.75.75 0 0 0 0 1.5h2.5a.75.75 0 0 0 0-1.5h-2.5Z" />
    </svg>
    """
  end

  defp source_icon(%{source: _} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
      <path fill-rule="evenodd" d="M2.94 6.412A2 2 0 0 1 4.913 4.75h6.174a2 2 0 0 1 1.973 1.662l.857 5.143A2 2 0 0 1 11.944 14H4.056a2 2 0 0 1-1.973-2.445l.857-5.143Z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-8 text-center">
      <div class="flex h-10 w-10 items-center justify-center rounded-full bg-gray-800 mb-3">
        <.empty_icon icon={@icon} />
      </div>
      <p class="text-sm text-gray-500">{@message}</p>
    </div>
    """
  end

  defp empty_icon(%{icon: "wrench"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-gray-500">
      <path fill-rule="evenodd" d="M11.943 1.257a.75.75 0 0 1 .763.067 3.004 3.004 0 0 1 .693 4.21l-.447.625L15 8.207a.75.75 0 0 1 0 1.06l-1.732 1.733a.75.75 0 0 1-1.06 0L10.16 8.952l-.625.447a3.004 3.004 0 0 1-4.21-.693.75.75 0 0 1-.067-.763L7.066 4.37l-1.9-1.9-1.152.768A.75.75 0 0 1 3 3.75v-2A.75.75 0 0 1 3.75 1h2a.75.75 0 0 1 .512.202l.768 1.152 1.9 1.9 3.573-1.807Z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp empty_icon(%{icon: "puzzle"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-gray-500">
      <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2a1.5 1.5 0 0 1 1.5 1.5V5h1A1.5 1.5 0 0 1 13 6.5v2A1.5 1.5 0 0 1 11.5 10H10v1.5A1.5 1.5 0 0 1 8.5 13h-2A1.5 1.5 0 0 1 5 11.5V10H3.5A1.5 1.5 0 0 1 2 8.5v-2A1.5 1.5 0 0 1 3.5 5H5V3.5Z" />
    </svg>
    """
  end

  defp empty_icon(%{icon: "server"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-gray-500">
      <path d="M3.5 2A1.5 1.5 0 0 0 2 3.5v2A1.5 1.5 0 0 0 3.5 7h9A1.5 1.5 0 0 0 14 5.5v-2A1.5 1.5 0 0 0 12.5 2h-9ZM3.5 9A1.5 1.5 0 0 0 2 10.5v2A1.5 1.5 0 0 0 3.5 14h9a1.5 1.5 0 0 0 1.5-1.5v-2A1.5 1.5 0 0 0 12.5 9h-9Z" />
    </svg>
    """
  end

  defp empty_icon(%{icon: _} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-gray-500">
      <path fill-rule="evenodd" d="M6.955 1.45A.5.5 0 0 1 7.452 1h1.096a.5.5 0 0 1 .497.45l.17 1.699c.484.12.94.312 1.356.562l1.321-.916a.5.5 0 0 1 .67.033l.774.775a.5.5 0 0 1 .034.67l-.916 1.32c.25.417.443.873.563 1.357l1.699.17a.5.5 0 0 1 .45.497v1.096a.5.5 0 0 1-.45.497l-1.699.17c-.12.484-.312.94-.562 1.356l.916 1.321a.5.5 0 0 1-.034.67l-.774.774a.5.5 0 0 1-.67.033l-1.32-.916c-.417.25-.874.443-1.357.563l-.17 1.699a.5.5 0 0 1-.497.45H7.452a.5.5 0 0 1-.497-.45l-.17-1.699a4.973 4.973 0 0 1-1.356-.562l-1.321.916a.5.5 0 0 1-.67-.034l-.774-.774a.5.5 0 0 1-.034-.67l.916-1.32a4.972 4.972 0 0 1-.563-1.357l-1.699-.17A.5.5 0 0 1 1 8.548V7.452a.5.5 0 0 1 .45-.497l1.699-.17c.12-.484.312-.94.562-1.356L2.795 4.108a.5.5 0 0 1 .034-.67l.774-.774a.5.5 0 0 1 .67-.033l1.32.916c.417-.25.874-.443 1.357-.563l.17-1.699ZM8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z" clip-rule="evenodd" />
    </svg>
    """
  end
end
