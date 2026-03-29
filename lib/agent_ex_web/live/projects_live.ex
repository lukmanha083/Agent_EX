defmodule AgentExWeb.ProjectsLive do
  use AgentExWeb, :live_view

  alias AgentEx.Projects

  import AgentExWeb.ProjectComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    projects = Projects.list_projects(user.id)

    {:ok,
     assign(socket,
       projects: projects,
       editing: nil,
       show_editor: false,
       form: empty_form()
     )}
  end

  @impl true
  def handle_event("new_project", _params, socket) do
    {:noreply,
     assign(socket,
       editing: nil,
       show_editor: true,
       form: empty_form()
     )}
  end

  def handle_event("edit_project", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Projects.get_user_project(user.id, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Project not found")}

      project ->
        {:noreply,
         assign(socket,
           editing: project,
           show_editor: true,
           form: project_to_form(project)
         )}
    end
  end

  def handle_event("close_editor", _params, socket) do
    {:noreply, assign(socket, show_editor: false, editing: nil)}
  end

  def handle_event("save_project", params, socket) do
    user = socket.assigns.current_scope.user

    result =
      if socket.assigns.editing do
        Projects.update_project(socket.assigns.editing, form_to_attrs(params))
      else
        Projects.create_project(Map.put(form_to_attrs(params), :user_id, user.id))
      end

    case result do
      {:ok, _project} ->
        projects = Projects.list_projects(user.id)

        {:noreply,
         socket
         |> assign(projects: projects, show_editor: false, editing: nil)
         |> put_flash(
           :info,
           if(socket.assigns.editing, do: "Project updated", else: "Project created")
         )}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(changeset.errors)}")}
    end
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

          {:error, :cannot_delete_default} ->
            {:noreply, put_flash(socket, :error, "Cannot delete the default project")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete project")}
        end
    end
  end

  defp empty_form do
    %{"name" => "", "description" => "", "root_path" => ""}
  end

  defp project_to_form(project) do
    %{
      "name" => project.name || "",
      "description" => project.description || "",
      "root_path" => project.root_path || ""
    }
  end

  defp form_to_attrs(params) do
    %{
      name: String.trim(params["name"] || ""),
      description: blank_to_nil(params["description"]),
      root_path: blank_to_nil(params["root_path"])
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
