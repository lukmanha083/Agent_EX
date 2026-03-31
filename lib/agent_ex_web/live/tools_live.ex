defmodule AgentExWeb.ToolsLive do
  use AgentExWeb, :live_view

  alias AgentEx.{HttpTool, HttpToolStore}

  import AgentExWeb.HttpToolComponents
  import AgentExWeb.ToolComponents

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns[:current_project]
    builtin = list_builtin_plugins()
    attached = MapSet.new(builtin, &{"built-in", &1.name})

    http_tools =
      if project && !project.is_default,
        do: HttpToolStore.list(user.id, project.id),
        else: []

    {:ok,
     assign(socket,
       builtin_plugins: builtin,
       available_plugins: [],
       mcp_servers: [],
       attached_sources: attached,
       show_mcp_form: false,
       mcp_form: %{name: "", transport: "stdio", command: ""},
       http_tools: http_tools,
       show_http_editor: false,
       http_form: empty_http_form(),
       editing_http_tool: false,
       http_test_result: nil,
       http_test_loading: false,
       http_test_ref: nil,
       http_test_pid: nil,
       active_tab: "builtin"
     )}
  end

  # --- MCP events (unchanged) ---

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
        id: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
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

  # --- HTTP tool events ---

  def handle_event("new_http_tool", _params, socket) do
    {:noreply,
     assign(socket,
       show_http_editor: true,
       http_form: empty_http_form(),
       editing_http_tool: false,
       http_test_result: nil
     )}
  end

  def handle_event("edit_http_tool", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.current_project

    case HttpToolStore.get(user.id, project.id, id) do
      {:ok, tool} ->
        form = %{
          "id" => tool.id,
          "name" => tool.name,
          "description" => tool.description,
          "method" => tool.method,
          "kind" => tool.kind,
          "url_template" => tool.url_template,
          "headers" => tool.headers,
          "parameters" => tool.parameters,
          "response_type" => tool.response_type,
          "response_path" => tool.response_path
        }

        {:noreply,
         assign(socket,
           show_http_editor: true,
           http_form: form,
           editing_http_tool: true,
           http_test_result: nil
         )}

      :not_found ->
        {:noreply, put_flash(socket, :error, "HTTP tool not found")}
    end
  end

  def handle_event("close_http_editor", _params, socket) do
    socket = cancel_http_test(socket)
    {:noreply, assign(socket, show_http_editor: false, http_test_result: nil)}
  end

  def handle_event("validate_http_tool", params, socket) do
    form = parse_http_form(params, socket.assigns.http_form)
    {:noreply, assign(socket, http_form: form)}
  end

  def handle_event("save_http_tool", params, socket) do
    form = parse_http_form(params, socket.assigns.http_form)
    name = String.trim(form["name"] || "")
    url_template = String.trim(form["url_template"] || "")

    if name == "" or url_template == "" do
      {:noreply, put_flash(socket, :error, "Name and URL template are required")}
    else
      attrs = build_http_attrs(form, params)
      do_save_http_tool(socket, form, attrs, name)
    end
  end

  def handle_event("delete_http_tool", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.current_project

    case HttpToolStore.delete(user.id, project.id, id) do
      :ok ->
        http_tools = HttpToolStore.list(user.id, project.id)

        {:noreply,
         socket
         |> assign(http_tools: http_tools, active_tab: "http")
         |> put_flash(:info, "HTTP tool deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("add_http_param", _params, socket) do
    params =
      (socket.assigns.http_form["parameters"] || []) ++
        [%{name: "", type: "string", description: "", required: false}]

    form = Map.put(socket.assigns.http_form, "parameters", params)
    {:noreply, assign(socket, http_form: form)}
  end

  def handle_event("remove_http_param", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    params = List.delete_at(socket.assigns.http_form["parameters"] || [], idx)
    form = Map.put(socket.assigns.http_form, "parameters", params)
    {:noreply, assign(socket, http_form: form)}
  end

  def handle_event("test_http_tool", _params, socket) do
    form = socket.assigns.http_form
    url_template = String.trim(form["url_template"] || "")

    if url_template == "" do
      {:noreply, put_flash(socket, :error, "URL template is required for testing")}
    else
      socket = cancel_http_test(socket)
      task = Task.Supervisor.async_nolink(AgentEx.TaskSupervisor, fn -> run_http_test(form) end)

      {:noreply,
       assign(socket,
         http_test_loading: true,
         http_test_result: nil,
         http_test_ref: task.ref,
         http_test_pid: task.pid
       )}
    end
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    if ref == socket.assigns[:http_test_ref] do
      Process.demonitor(ref, [:flush])

      {:noreply,
       assign(socket,
         http_test_result: result,
         http_test_loading: false,
         http_test_ref: nil,
         http_test_pid: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if ref == socket.assigns[:http_test_ref] do
      {:noreply,
       assign(socket,
         http_test_result: "Test failed: #{inspect(reason)}",
         http_test_loading: false,
         http_test_ref: nil,
         http_test_pid: nil
       )}
    else
      {:noreply, socket}
    end
  end

  defp cancel_http_test(socket) do
    if pid = socket.assigns[:http_test_pid] do
      Process.demonitor(socket.assigns[:http_test_ref], [:flush])
      Process.exit(pid, :shutdown)
      assign(socket, http_test_ref: nil, http_test_pid: nil, http_test_loading: false)
    else
      socket
    end
  end

  # --- HTTP test helper ---

  @method_map %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete
  }

  defp run_http_test(form) do
    headers = form["headers"] || %{}
    method = Map.get(@method_map, String.downcase(form["method"] || "get"), :get)
    url = fill_test_placeholders(form["url_template"] || "")
    headers = fill_test_headers(headers)

    case AgentEx.NetworkPolicy.validate(url) do
      {:error, reason} -> "Blocked: #{reason}"
      :ok -> do_http_test_request(method, url, headers)
    end
  end

  defp do_http_test_request(method, url, headers) do
    case Req.request(method: method, url: url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: status, body: body}} ->
        body_str = if is_binary(body), do: body, else: Jason.encode!(body, pretty: true)
        "HTTP #{status}\n#{String.slice(body_str, 0, 500)}"

      {:error, exception} ->
        "Error: #{inspect(exception)}"
    end
  end

  defp fill_test_placeholders(url) do
    Regex.replace(~r/\{\{(\w+)\}\}/, url, fn _match, key -> "test_#{key}" end)
  end

  defp fill_test_headers(headers) when is_map(headers) do
    Map.new(headers, fn {k, v} ->
      {k, Regex.replace(~r/\{\{(\w+)\}\}/, v, fn _match, key -> "test_#{key}" end)}
    end)
  end

  defp fill_test_headers(headers), do: headers

  # --- Private helpers ---

  defp do_save_http_tool(socket, form, attrs, name) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.current_project

    if socket.assigns.editing_http_tool && form["id"] do
      update_existing_http_tool(socket, user, project, form["id"], attrs)
    else
      config =
        HttpTool.new(Map.merge(attrs, %{user_id: user.id, project_id: project.id, name: name}))

      save_and_refresh(socket, config, "HTTP tool created")
    end
  end

  defp update_existing_http_tool(socket, user, project, tool_id, attrs) do
    case HttpToolStore.get(user.id, project.id, tool_id) do
      {:ok, existing} ->
        save_and_refresh(socket, HttpTool.update(existing, attrs), "HTTP tool updated")

      :not_found ->
        {:noreply, put_flash(socket, :error, "HTTP tool not found")}
    end
  end

  defp build_http_attrs(form, params) do
    kind = if to_string(form["kind"]) == "write", do: :write, else: :read
    headers = parse_headers(params["headers_json"])

    %{
      name: String.trim(form["name"] || ""),
      description: form["description"],
      method: form["method"] || "GET",
      kind: kind,
      url_template: String.trim(form["url_template"] || ""),
      headers: headers,
      parameters: (form["parameters"] || []) |> Enum.reject(fn p -> p.name == "" end),
      response_type: form["response_type"],
      response_path: form["response_path"]
    }
  end

  defp save_and_refresh(socket, config, flash_msg) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.current_project

    case HttpToolStore.save(config) do
      {:ok, _} ->
        http_tools = HttpToolStore.list(user.id, project.id)

        {:noreply,
         socket
         |> assign(
           http_tools: http_tools,
           show_http_editor: false,
           http_test_result: nil,
           active_tab: "http"
         )
         |> put_flash(:info, flash_msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  defp parse_http_form(params, current) do
    parameters = parse_params(params["params"])

    fields = %{
      "id" => params["tool_id"],
      "name" => params["name"],
      "description" => params["description"],
      "method" => params["method"],
      "kind" => params["kind"],
      "url_template" => params["url_template"],
      "headers" => parse_headers(params["headers_json"]),
      "parameters" => parameters,
      "response_type" => params["response_type"],
      "response_path" => params["response_path"]
    }

    Map.merge(current, fields, fn _k, old, new -> new || old end)
  end

  defp parse_params(nil), do: nil

  defp parse_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_idx, p} ->
      %{
        name: p["name"] || "",
        type: p["type"] || "string",
        description: p["description"] || "",
        required: p["required"] == "true"
      }
    end)
  end

  defp parse_params(_), do: nil

  defp parse_headers(nil), do: nil
  defp parse_headers(""), do: %{}

  defp parse_headers(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp parse_headers(_), do: nil

  defp empty_http_form do
    %{
      "id" => nil,
      "name" => "",
      "description" => "",
      "method" => "GET",
      "kind" => "read",
      "url_template" => "",
      "headers" => %{},
      "parameters" => [],
      "response_type" => "json_body",
      "response_path" => ""
    }
  end

  defp update_mcp_attached(socket, "mcp", name, value) do
    servers =
      Enum.map(socket.assigns.mcp_servers, fn s ->
        if s.id == name or s.name == name, do: Map.put(s, :attached, value), else: s
      end)

    assign(socket, mcp_servers: servers)
  end

  defp update_mcp_attached(socket, _source, _name, _value), do: socket

  defp list_builtin_plugins do
    Enum.map(AgentEx.ToolAssembler.builtin_plugin_modules(), fn mod ->
      manifest = mod.manifest()

      %{
        name: manifest.name,
        description: manifest.description,
        version: manifest.version,
        tool_names: list_plugin_tool_names(mod, manifest)
      }
    end)
  end

  defp list_plugin_tool_names(mod, manifest) do
    # Try to init with minimal config to discover tool names
    # Fall back to just showing the plugin name if init requires config
    case safe_plugin_init(mod) do
      {:ok, tools} ->
        Enum.map(tools, &"#{manifest.name}.#{&1.name}")

      :config_required ->
        ["#{manifest.name}.*"]
    end
  end

  defp safe_plugin_init(mod) do
    schema = mod.manifest().config_schema

    # Build a minimal config with placeholder values for required fields
    config =
      Enum.reduce(schema, %{}, fn param, acc ->
        {name, type, _desc, opts} = normalize_plugin_param(param)
        key = Atom.to_string(name)
        optional = Keyword.get(opts, :optional, false)

        if optional do
          acc
        else
          Map.put(acc, key, placeholder_value(type))
        end
      end)

    case mod.init(config) do
      {:ok, tools} -> {:ok, tools}
      {:stateful, tools, _} -> {:ok, tools}
      _ -> :config_required
    end
  rescue
    _ -> :config_required
  end

  defp normalize_plugin_param({name, type, desc}), do: {name, type, desc, []}
  defp normalize_plugin_param({name, type, desc, opts}), do: {name, type, desc, opts}

  defp placeholder_value(:string), do: System.tmp_dir!()
  defp placeholder_value(:integer), do: 0
  defp placeholder_value(:boolean), do: false
  defp placeholder_value({:array, _}), do: []
  defp placeholder_value(_), do: ""

end
