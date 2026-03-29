defmodule AgentExWeb.ToolComponents do
  @moduledoc """
  Components for the unified tool manager — tool source tabs,
  tool cards, MCP connect form, and plugin browser.
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]
  import SaladUI.Button
  import SaladUI.Tabs

  # --- Tool source tabs ---

  @doc "Renders the tabbed tool management panel."
  attr(:active_tab, :string, default: "builtin")
  attr(:builtin_plugins, :list, default: [])
  attr(:available_plugins, :list, default: [])
  attr(:mcp_servers, :list, default: [])
  attr(:custom_tools, :list, default: [])
  attr(:attached_sources, :any, default: nil)

  def tool_tabs(assigns) do
    ~H"""
    <.tabs id="tool-tabs" default={@active_tab} class="w-full">
      <.tabs_list class="bg-gray-800/50 border border-gray-700 mb-4">
        <.tabs_trigger value="builtin" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          Built-in
        </.tabs_trigger>
        <.tabs_trigger value="plugins" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          Plugins
        </.tabs_trigger>
        <.tabs_trigger value="mcp" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          MCP Servers
        </.tabs_trigger>
        <.tabs_trigger value="custom" class="data-[state=active]:bg-gray-700 text-gray-300 data-[state=active]:text-white">
          Custom
        </.tabs_trigger>
      </.tabs_list>

      <.tabs_content value="builtin">
        <.builtin_tools_panel plugins={@builtin_plugins} attached_sources={@attached_sources} />
      </.tabs_content>

      <.tabs_content value="plugins">
        <.plugin_browser plugins={@available_plugins} attached_sources={@attached_sources} />
      </.tabs_content>

      <.tabs_content value="mcp">
        <.mcp_panel servers={@mcp_servers} />
      </.tabs_content>

      <.tabs_content value="custom">
        <.custom_tools_panel tools={@custom_tools} />
      </.tabs_content>
    </.tabs>
    """
  end

  # --- Built-in tools (FileSystem, ShellExec) ---

  attr(:plugins, :list, default: [])
  attr(:attached_sources, :any, default: nil)

  defp builtin_tools_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-gray-400 mb-4">
        Built-in tool plugins that ship with AgentEx.
      </p>
      <%= if @plugins == [] do %>
        <.empty_state icon="wrench" message="No built-in plugins attached" />
      <% else %>
        <.tool_source_card
          :for={plugin <- @plugins}
          name={plugin.name}
          description={plugin.description}
          version={plugin.version}
          tool_count={length(plugin.tool_names)}
          source="built-in"
          attached={@attached_sources && MapSet.member?(@attached_sources, {"built-in", plugin.name})}
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
        <p class="text-sm text-gray-400">Available tool plugins</p>
        <button
          type="button"
          phx-click="refresh_plugins"
          class="text-xs text-indigo-400 hover:text-indigo-300 transition-colors"
        >
          Refresh
        </button>
      </div>
      <%= if @plugins == [] do %>
        <.empty_state icon="puzzle" message="No plugins available. Add plugins to your project and register them here." />
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

  # --- Custom tools ---

  attr(:tools, :list, default: [])

  defp custom_tools_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between mb-2">
        <p class="text-sm text-gray-400">User-defined tools</p>
        <button
          type="button"
          phx-click="new_custom_tool"
          class="inline-flex items-center gap-1.5 rounded-md bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New Tool
        </button>
      </div>

      <%= if @tools == [] do %>
        <.empty_state icon="code" message="No custom tools defined yet" />
      <% else %>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <.tool_card :for={tool <- @tools} tool={tool} />
        </div>
      <% end %>
    </div>
    """
  end

  # --- Shared components ---

  @doc "Renders a tool source card (plugin, MCP server, etc.)."
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
