defmodule AgentExWeb.WorkflowsLive do
  use AgentExWeb, :live_view

  alias AgentEx.Workflow.{Edge, Node, Runner}
  alias AgentEx.Workflows

  import AgentExWeb.WorkflowComponents

  @impl true
  def mount(_params, _session, socket) do
    project = socket.assigns[:current_project]

    workflows = if project, do: Workflows.list_workflows(project.id), else: []

    agents =
      if project do
        user = socket.assigns.current_scope.user
        AgentEx.AgentStore.list(user.id, project.id)
      else
        []
      end

    {:ok,
     assign(socket,
       workflows: workflows,
       agents: agents,
       editing: nil,
       selected_node_id: nil,
       run_result: nil,
       run_loading: false
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    project = socket.assigns[:current_project]
    unless project, do: throw(:noreply)

    case Workflows.get_workflow(project.id, id) do
      {:ok, workflow} ->
        {:noreply,
         assign(socket,
           editing: workflow,
           selected_node_id: nil,
           run_result: nil
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workflow not found")
         |> push_navigate(to: ~p"/workflows")}
    end
  catch
    :noreply -> {:noreply, push_navigate(socket, to: ~p"/workflows")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, editing: nil, selected_node_id: nil)}
  end

  # --- Events: Workflow CRUD ---

  @impl true
  def handle_event("new_workflow", _params, socket) do
    project = socket.assigns.current_project

    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)

    attrs = %{
      project_id: project.id,
      name: "Workflow #{suffix}",
      nodes: [
        %Node{
          id: gen_node_id(),
          type: :trigger,
          label: "Trigger",
          position: %{"x" => 50, "y" => 100}
        },
        %Node{
          id: gen_node_id(),
          type: :output,
          label: "Output",
          position: %{"x" => 350, "y" => 100}
        }
      ],
      edges: []
    }

    case Workflows.create_workflow(attrs) do
      {:ok, saved} ->
        {:noreply, push_navigate(socket, to: ~p"/workflows/#{saved.id}")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("edit_workflow", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workflows/#{id}")}
  end

  def handle_event("delete_workflow", %{"id" => id}, socket) do
    project = socket.assigns.current_project

    case Workflows.delete_workflow(project.id, id) do
      {:ok, _} ->
        workflows = Workflows.list_workflows(project.id)

        {:noreply,
         socket
         |> assign(workflows: workflows, editing: nil)
         |> push_navigate(to: ~p"/workflows")
         |> put_flash(:info, "Workflow deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save_workflow", params, socket) do
    editing = socket.assigns.editing
    unless editing, do: throw(:noreply)

    name = String.trim(params["name"] || editing.name)
    description = params["description"]

    case Workflows.update_workflow(editing, %{name: name, description: description}) do
      {:ok, saved} ->
        workflows = Workflows.list_workflows(saved.project_id)

        {:noreply,
         socket
         |> assign(editing: saved, workflows: workflows)
         |> put_flash(:info, "Workflow saved")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(changeset.errors)}")}
    end
  catch
    :noreply -> {:noreply, socket}
  end

  def handle_event("back_to_list", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workflows")}
  end

  # --- Events: Node management ---

  def handle_event("add_node", %{"type" => type}, socket) do
    editing = socket.assigns.editing
    unless editing, do: throw(:noreply)

    max_y =
      editing.nodes
      |> Enum.map(&((&1.position["y"] || 0) + 60))
      |> Enum.max(fn -> 50 end)

    node = %Node{
      id: gen_node_id(),
      type: String.to_existing_atom(type),
      label: type_label(type),
      config: %{},
      position: %{"x" => 200, "y" => max_y}
    }

    save_editing(socket, %{nodes: editing.nodes ++ [node]}, node.id)
  catch
    :noreply -> {:noreply, socket}
  end

  def handle_event("select_node", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_node_id: id)}
  end

  def handle_event("deselect_node", _params, socket) do
    {:noreply, assign(socket, selected_node_id: nil)}
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    editing = socket.assigns.editing
    unless editing, do: throw(:noreply)

    nodes = Enum.reject(editing.nodes, &(&1.id == id))
    edges = Enum.reject(editing.edges, &(&1.source_node_id == id || &1.target_node_id == id))

    save_editing(socket, %{nodes: nodes, edges: edges}, nil)
  catch
    :noreply -> {:noreply, socket}
  end

  def handle_event("update_node_label", %{"id" => id, "value" => label}, socket) do
    update_node(socket, id, fn node -> %{node | label: label} end)
  end

  def handle_event("update_node_config", %{"id" => id, "key" => key, "value" => value}, socket) do
    update_node(socket, id, fn node ->
      %{node | config: Map.put(node.config, key, value)}
    end)
  end

  def handle_event(
        "update_node_config_value",
        %{"id" => id, "key" => key, "value" => value},
        socket
      ) do
    update_node(socket, id, fn node ->
      parsed =
        if key == "paths",
          do: String.split(value, "\n", trim: true) |> Enum.map(&String.trim/1),
          else: value

      %{node | config: Map.put(node.config, key, parsed)}
    end)
  end

  def handle_event(
        "update_node_config_json",
        %{"id" => id, "key" => key, "value" => json},
        socket
      ) do
    case Jason.decode(json) do
      {:ok, parsed} ->
        update_node(socket, id, fn node -> %{node | config: Map.put(node.config, key, parsed)} end)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid JSON")}
    end
  end

  def handle_event("move_node", %{"id" => id, "x" => x, "y" => y}, socket) do
    update_node(socket, id, fn node -> %{node | position: %{"x" => x, "y" => y}} end)
  end

  # --- Events: Edge management ---

  def handle_event("add_edge", %{"source" => source, "target" => target} = params, socket) do
    editing = socket.assigns.editing
    unless editing, do: throw(:noreply)

    edge = %Edge{
      id: gen_edge_id(),
      source_node_id: source,
      target_node_id: target,
      source_port: params["source_port"] || "output",
      target_port: params["target_port"] || "input"
    }

    save_editing(socket, %{edges: editing.edges ++ [edge]}, socket.assigns.selected_node_id)
  catch
    :noreply -> {:noreply, socket}
  end

  def handle_event("delete_edge", %{"id" => id}, socket) do
    editing = socket.assigns.editing
    unless editing, do: throw(:noreply)

    edges = Enum.reject(editing.edges, &(&1.id == id))
    save_editing(socket, %{edges: edges}, socket.assigns.selected_node_id)
  catch
    :noreply -> {:noreply, socket}
  end

  # --- Events: Run workflow ---

  def handle_event("run_workflow", _params, socket) do
    editing = socket.assigns.editing
    unless editing, do: throw(:noreply)

    task =
      Task.Supervisor.async_nolink(AgentEx.TaskSupervisor, fn ->
        Runner.run(editing, %{})
      end)

    {:noreply,
     assign(socket,
       run_loading: true,
       run_result: nil,
       run_ref: task.ref,
       run_pid: task.pid
     )}
  catch
    :noreply -> {:noreply, socket}
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    if ref == socket.assigns[:run_ref] do
      Process.demonitor(ref, [:flush])

      run_result =
        case result do
          {:ok, %{output: output}} ->
            %{status: :ok, output: output}

          {:error, %{node_id: node_id, reason: reason}} ->
            %{status: :error, node_id: node_id, reason: reason}
        end

      {:noreply,
       assign(socket, run_result: run_result, run_loading: false, run_ref: nil, run_pid: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if ref == socket.assigns[:run_ref] do
      {:noreply,
       assign(socket,
         run_result: %{status: :error, node_id: nil, reason: inspect(reason)},
         run_loading: false,
         run_ref: nil,
         run_pid: nil
       )}
    else
      {:noreply, socket}
    end
  end

  # --- Private ---

  defp update_node(socket, id, update_fn) do
    editing = socket.assigns.editing
    unless editing, do: throw(:noreply)

    nodes =
      Enum.map(editing.nodes, fn node -> if node.id == id, do: update_fn.(node), else: node end)

    save_editing(socket, %{nodes: nodes}, socket.assigns.selected_node_id)
  catch
    :noreply -> {:noreply, socket}
  end

  defp save_editing(socket, attrs, selected_node_id) do
    case Workflows.update_workflow(socket.assigns.editing, attrs) do
      {:ok, saved} ->
        {:noreply, assign(socket, editing: saved, selected_node_id: selected_node_id)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(changeset.errors)}")}
    end
  end

  defp selected_node(editing, selected_id) do
    if editing && selected_id do
      Enum.find(editing.nodes, &(&1.id == selected_id))
    end
  end

  defp type_label(type) do
    type
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_result(%{status: :ok, output: output}) when is_binary(output), do: output
  defp format_result(%{status: :ok, output: output}), do: Jason.encode!(output, pretty: true)
  defp format_result(%{status: :error, reason: reason}), do: inspect(reason)
  defp format_result(_), do: ""

  defp gen_node_id, do: "n-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
  defp gen_edge_id, do: "e-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
end
