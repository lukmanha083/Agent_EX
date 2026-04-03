defmodule AgentExWeb.ProjectsLive do
  use AgentExWeb, :live_view

  alias AgentEx.Projects

  import AgentExWeb.ProjectComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    projects = Projects.list_projects(user.id)

    {:ok, assign(socket, projects: projects)}
  end

  @impl true
  def handle_event("new_project", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects/new")}
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Projects.get_user_project(user.id, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Project not found")}

      project ->
        case Projects.delete_project(project) do
          {:ok, _} ->
            projects = Projects.list_projects(user.id)

            {:noreply,
             socket
             |> assign(projects: projects)
             |> put_flash(:info, "Project deleted")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete project")}
        end
    end
  end
end
