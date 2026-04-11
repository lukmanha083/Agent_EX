defmodule AgentExWeb.McpServersLive do
  use AgentExWeb, :live_view

  alias AgentEx.MCP.Servers

  import AgentExWeb.CoreComponents, except: [button: 1]
  import SaladUI.Button

  @impl true
  def mount(_params, _session, socket) do
    project = socket.assigns[:current_project]

    if is_nil(project) do
      {:ok,
       socket
       |> put_flash(:error, "No project available.")
       |> redirect(to: ~p"/projects")}
    else
      servers = Servers.list_all(project.id)

      {:ok,
       assign(socket,
         project: project,
         servers: servers,
         show_editor: false,
         editing: nil,
         form: empty_form()
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-4 py-8">
      <div class="mb-6">
        <h1 class="text-2xl font-bold text-white">Built-in MCP Servers</h1>
        <p class="text-sm text-gray-400 mt-1">
          <.link href="https://modelcontextprotocol.io" target="_blank" rel="noopener noreferrer" class="text-indigo-400 hover:text-indigo-300">Model Context Protocol</.link>
          servers for server-side tool execution. Claude calls these directly during inference.
        </p>
        <p class="text-xs text-amber-400/80 mt-2">
          This feature is specific to Anthropic models (Claude). Server-side MCP is not available for other providers.
        </p>
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
              <button
                type="button"
                phx-click="edit_server"
                phx-value-id={server.id}
                class="p-1.5 rounded-md text-gray-400 hover:text-white hover:bg-gray-800 transition-colors"
                aria-label="Edit server"
              >
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
                  <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
                  <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.5A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
                </svg>
              </button>
              <button
                type="button"
                phx-click="delete_server"
                phx-value-id={server.id}
                data-confirm="Delete this MCP server?"
                class="p-1.5 rounded-md text-gray-400 hover:text-red-400 hover:bg-gray-800 transition-colors"
                aria-label="Delete server"
              >
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
              phx-click={unless server.system, do: "toggle_server"}
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
      <div :if={@show_editor} class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true" aria-labelledby="mcp-editor-title" phx-window-keydown="close_editor" phx-key="Escape">
        <div class="fixed inset-0 bg-black/60" phx-click="close_editor"></div>
        <div class="relative z-10 w-full max-w-lg mx-4 rounded-lg border border-gray-800 bg-gray-900 shadow-xl">
          <div class="p-6 pb-0">
            <h2 id="mcp-editor-title" class="text-lg font-semibold text-white">
              {if @editing, do: "Edit MCP Server", else: "Add MCP Server"}
            </h2>
          </div>

          <.form for={@form} phx-submit="save_server" class="p-6 space-y-4">
            <input :if={@editing} type="hidden" name="server_id" value={@editing.id} />

            <.input type="text" name="name" value={@form["name"]} label="Name" placeholder="e.g. context7" required />
            <.input type="text" name="url" value={@form["url"]} label="URL (SSE endpoint)" placeholder="https://mcp.example.com/sse" required />
            <.input type="text" name="description" value={@form["description"]} label="Description" placeholder="What this server provides" />
            <input type="hidden" name="provider" value="anthropic" />
            <.input type="text" name="auth_token_key" value={@form["auth_token_key"]} label="Vault Key (for auth token)" placeholder="e.g. mcp:github" />
            <p class="text-[10px] text-gray-500 -mt-2">Store the token in Vault with this key. Leave blank for public servers.</p>

            <div class="flex justify-end gap-2 pt-2">
              <.button type="button" variant="outline" phx-click="close_editor" class="border-gray-700 text-gray-300">
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

  @impl true
  def handle_event("edit_server", %{"id" => id}, socket) do
    case Servers.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Server not found")}

      %{system: true} ->
        {:noreply, put_flash(socket, :error, "System servers cannot be modified")}

      %{project_id: pid} when pid != socket.assigns.project.id ->
        {:noreply, put_flash(socket, :error, "Server not found")}

      server ->
        form = %{
          "name" => server.name,
          "url" => server.url,
          "description" => server.description || "",
          "provider" => server.provider,
          "auth_token_key" => server.auth_token_key || ""
        }

        {:noreply, assign(socket, show_editor: true, editing: server, form: form)}
    end
  end

  def handle_event("close_editor", _params, socket) do
    {:noreply, assign(socket, show_editor: false, editing: nil)}
  end

  def handle_event("save_server", params, socket) do
    project_id = socket.assigns.project.id

    editing = socket.assigns.editing

    if editing && editing.system do
      {:noreply, put_flash(socket, :error, "System servers cannot be modified")}
    else
      attrs = build_server_attrs(params, project_id)

      result =
        if editing,
          do: Servers.update_server(editing, attrs),
          else: Servers.create(attrs)

      handle_save_result(result, params, socket)
    end
  end

  def handle_event("delete_server", %{"id" => id}, socket) do
    project_id = socket.assigns.project.id

    case Servers.get(id) do
      nil ->
        {:noreply, socket}

      %{system: true} ->
        {:noreply, put_flash(socket, :error, "System servers cannot be deleted")}

      %{project_id: pid} when pid != project_id ->
        {:noreply, socket}

      server ->
        case Servers.delete(server) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(servers: Servers.list_all(project_id))
             |> put_flash(:info, "Server deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete")}
        end
    end
  end

  def handle_event("toggle_server", %{"id" => id}, socket) do
    project_id = socket.assigns.project.id

    case Servers.get(id) do
      nil ->
        {:noreply, socket}

      %{system: true} ->
        {:noreply, put_flash(socket, :error, "System servers cannot be modified")}

      %{project_id: pid} when pid != project_id ->
        {:noreply, socket}

      _server ->
        case Servers.toggle(id) do
          {:ok, _} ->
            {:noreply, assign(socket, servers: Servers.list_all(project_id))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle")}
        end
    end
  end

  defp build_server_attrs(params, project_id) do
    %{
      name: params["name"],
      url: params["url"],
      description: blank_to_nil(params["description"]),
      provider: params["provider"] || "anthropic",
      auth_token_key: blank_to_nil(params["auth_token_key"]),
      project_id: project_id
    }
  end

  defp handle_save_result({:ok, _}, _params, socket) do
    project_id = socket.assigns.project.id
    msg = if socket.assigns.editing, do: "Server updated", else: "Server added"

    {:noreply,
     socket
     |> assign(servers: Servers.list_all(project_id), show_editor: false, editing: nil)
     |> put_flash(:info, msg)}
  end

  defp handle_save_result({:error, changeset}, params, socket) do
    errors = Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

    form = %{
      "name" => params["name"] || "",
      "url" => params["url"] || "",
      "description" => params["description"] || "",
      "provider" => params["provider"] || "anthropic",
      "auth_token_key" => params["auth_token_key"] || ""
    }

    {:noreply,
     socket
     |> assign(form: form)
     |> put_flash(:error, "Failed: #{errors}")}
  end

  defp empty_form do
    %{
      "name" => "",
      "url" => "",
      "description" => "",
      "provider" => "anthropic",
      "auth_token_key" => ""
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
