defmodule AgentExWeb.ToolsLive do
  use AgentExWeb, :live_view

  import AgentExWeb.ToolComponents

  @impl true
  def mount(_params, _session, socket) do
    builtin = list_builtin_plugins()
    attached = MapSet.new(builtin, &{"built-in", &1.name})

    {:ok,
     assign(socket,
       builtin_plugins: builtin,
       available_plugins: [],
       mcp_servers: [],
       custom_tools: list_demo_tools(),
       attached_sources: attached,
       show_mcp_form: false,
       mcp_form: %{name: "", transport: "stdio", command: ""}
     )}
  end

  @impl true
  def handle_event("show_mcp_form", _params, socket) do
    {:noreply, assign(socket, show_mcp_form: true)}
  end

  def handle_event("close_mcp_form", _params, socket) do
    {:noreply, assign(socket, show_mcp_form: false)}
  end

  def handle_event("connect_mcp", params, socket) do
    name = String.trim(params["name"] || "")
    transport = String.trim(params["transport"] || "")
    command = String.trim(params["command"] || "")

    if name == "" or command == "" do
      {:noreply, put_flash(socket, :error, "Name and command are required")}
    else
      server = %{
        name: name,
        transport: transport,
        command: command,
        tool_count: 0
      }

      mcp_servers = socket.assigns.mcp_servers ++ [server]

      {:noreply,
       socket
       |> assign(mcp_servers: mcp_servers, show_mcp_form: false)
       |> put_flash(:info, "MCP server '#{server.name}' added (connect on next agent run)")}
    end
  end

  def handle_event("refresh_plugins", _params, socket) do
    {:noreply, assign(socket, available_plugins: [])}
  end

  def handle_event("new_custom_tool", _params, socket) do
    {:noreply, put_flash(socket, :info, "Custom tool editor coming in a future update")}
  end

  def handle_event("detach_source", %{"name" => name, "source" => source}, socket) do
    attached = MapSet.delete(socket.assigns.attached_sources, {source, name})

    {:noreply,
     socket
     |> update_mcp_attached(source, name, false)
     |> assign(attached_sources: attached)
     |> put_flash(:info, "Detached #{name}")}
  end

  def handle_event("attach_source", %{"name" => name, "source" => source}, socket) do
    attached = MapSet.put(socket.assigns.attached_sources, {source, name})

    {:noreply,
     socket
     |> update_mcp_attached(source, name, true)
     |> assign(attached_sources: attached)
     |> put_flash(:info, "Attached #{name}")}
  end

  def handle_event(event, _params, socket)
      when event in ["detach_source", "attach_source"] do
    {:noreply, put_flash(socket, :error, "Invalid request")}
  end

  defp update_mcp_attached(socket, "mcp", name, value) do
    servers =
      Enum.map(socket.assigns.mcp_servers, fn s ->
        if s.name == name, do: Map.put(s, :attached, value), else: s
      end)

    assign(socket, mcp_servers: servers)
  end

  defp update_mcp_attached(socket, _source, _name, _value), do: socket

  # --- Private helpers ---

  defp list_builtin_plugins do
    [
      %{
        name: "filesystem",
        description: "Sandboxed file system operations (read, write, list)",
        version: "1.0.0",
        tool_names: ["filesystem.read_file", "filesystem.write_file", "filesystem.list_dir"]
      },
      %{
        name: "shell_exec",
        description: "Sandboxed shell command execution with allowlist",
        version: "1.0.0",
        tool_names: ["shell_exec.run"]
      }
    ]
  end

  defp list_demo_tools do
    [
      %{
        name: "get_system_info",
        description: "Get OS name, kernel version, and architecture",
        kind: :read
      },
      %{
        name: "get_disk_usage",
        description: "Get disk space usage for all mounted filesystems",
        kind: :read
      },
      %{
        name: "get_current_time",
        description: "Get the current date and time with timezone",
        kind: :read
      }
    ]
  end
end
