defmodule AgentExWeb.ProjectsLive do
  use AgentExWeb, :live_view

  alias AgentEx.Projects

  import AgentExWeb.ProjectComponents

  import AgentExWeb.ProviderHelpers,
    only: [
      default_model_for: 1,
      provider_options: 0,
      models_for_provider: 1,
      context_window_for: 1,
      format_context_window: 1
    ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    projects = Projects.list_projects(user.id)
    default_provider = "anthropic"
    default_model = default_model_for(default_provider)

    {:ok,
     assign(socket,
       projects: projects,
       editing: nil,
       show_editor: false,
       form: empty_form(default_provider, default_model),
       selected_provider: default_provider,
       provider_options: provider_options(),
       model_options: model_select_options(default_provider),
       context_window_display: format_context_window(context_window_for(default_model))
     )}
  end

  @impl true
  def handle_event("new_project", _params, socket) do
    default_provider = "anthropic"
    default_model = default_model_for(default_provider)

    {:noreply,
     assign(socket,
       editing: nil,
       show_editor: true,
       form: empty_form(default_provider, default_model),
       selected_provider: default_provider,
       model_options: model_select_options(default_provider),
       context_window_display: format_context_window(context_window_for(default_model))
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

  def handle_event("validate_project", params, socket) do
    new_provider = params["provider"] || socket.assigns.selected_provider
    provider_changed? = new_provider != socket.assigns.selected_provider
    current_model = resolve_current_model(params, socket.assigns, provider_changed?, new_provider)
    form = merge_project_form(socket.assigns.form, params, new_provider, current_model)

    socket =
      if provider_changed? do
        assign(socket,
          selected_provider: new_provider,
          model_options: model_select_options(new_provider)
        )
      else
        socket
      end

    {:noreply,
     assign(socket,
       form: form,
       context_window_display: format_context_window(context_window_for(current_model))
     )}
  end

  def handle_event("save_project", params, socket) do
    user = socket.assigns.current_scope.user

    result =
      if socket.assigns.editing do
        Projects.update_project(socket.assigns.editing, form_to_attrs(params))
      else
        Projects.create_project(
          form_to_attrs(params)
          |> Map.put(:user_id, user.id)
          |> Map.put(:provider, params["provider"] || "anthropic")
          |> Map.put(
            :model,
            params["model"] || default_model_for(params["provider"] || "anthropic")
          )
        )
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

  defp resolve_current_model(_params, _assigns, true, new_provider),
    do: default_model_for(new_provider)

  defp resolve_current_model(params, assigns, false, _provider),
    do: params["model"] || assigns.form["model"] || ""

  defp merge_project_form(form, params, provider, model) do
    Map.merge(form, %{
      "name" => params["name"] || form["name"],
      "description" => params["description"] || form["description"],
      "root_path" => params["root_path"] || form["root_path"],
      "provider" => provider,
      "model" => model
    })
  end

  defp empty_form(provider, model) do
    %{
      "name" => "",
      "description" => "",
      "root_path" => "",
      "provider" => provider,
      "model" => model
    }
  end

  defp model_select_options(provider) do
    Enum.map(models_for_provider(provider), fn m -> {m, m} end)
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
