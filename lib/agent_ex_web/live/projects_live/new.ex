defmodule AgentExWeb.ProjectsLive.New do
  @moduledoc "Onboarding page for creating a new project. Also used for adding projects later."
  use AgentExWeb, :live_view

  alias AgentEx.Projects

  import AgentExWeb.ProviderHelpers,
    only: [
      default_model_for: 1,
      provider_options: 0,
      models_for_provider: 1,
      context_window_for: 1,
      format_context_window: 1
    ]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center p-4 bg-gray-950">
      <div class="w-full max-w-lg">
        <div class="text-center mb-8">
          <div class="flex items-center justify-center gap-2 mb-4">
            <div class="flex h-10 w-10 items-center justify-center rounded-lg bg-indigo-600">
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-white">
                <path d="M3.75 3A1.75 1.75 0 0 0 2 4.75v3.26a3.235 3.235 0 0 1 1.75-.51h12.5c.644 0 1.245.188 1.75.51V6.75A1.75 1.75 0 0 0 16.25 5h-4.836a.25.25 0 0 1-.177-.073L9.823 3.513A1.75 1.75 0 0 0 8.586 3H3.75ZM3.75 9A1.75 1.75 0 0 0 2 10.75v4.5c0 .966.784 1.75 1.75 1.75h12.5A1.75 1.75 0 0 0 18 15.25v-4.5A1.75 1.75 0 0 0 16.25 9H3.75Z" />
              </svg>
            </div>
            <h1 class="text-2xl font-bold text-white">Create a Project</h1>
          </div>
          <p class="text-gray-400 text-sm">
            Projects organize your agents, conversations, tools, and memory into isolated workspaces.
            Choose your LLM provider and model — these are locked after creation.
          </p>
        </div>

        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6">
          <.form for={@form} phx-submit="create_project" phx-change="validate" class="space-y-4">
            <.input type="text" name="name" value={@form["name"]} label="Project Name" placeholder="e.g. Stock Research" required />
            <.input type="text" name="description" value={@form["description"]} label="Description" placeholder="What this project is for" />
            <.input type="text" name="root_path" value={@form["root_path"]} label="Sandbox Root Path" placeholder="e.g. ~/projects/trading" />
            <p class="text-[10px] text-gray-500 -mt-2">
              Agents in this project will be confined to this directory.
            </p>

            <fieldset class="border-t border-gray-800 pt-4">
              <legend class="text-xs font-medium text-gray-500 uppercase tracking-wider">LLM Provider</legend>
              <div class="grid grid-cols-2 gap-3 mt-3">
                <.input type="select" name="provider" value={@form["provider"]} label="Provider" options={@provider_options} />
                <.input type="select" name="model" value={@form["model"]} label="Model" options={@model_options} />
              </div>
              <div class="flex items-center gap-2 rounded-md bg-gray-800/50 border border-gray-700 px-3 py-2 mt-3">
                <span class="text-xs text-gray-400">Context window:</span>
                <span class="text-xs font-mono text-white">{@context_window_display}</span>
                <span class="text-xs text-gray-500">tokens</span>
              </div>
            </fieldset>

            <.button type="submit" class="w-full bg-indigo-600 hover:bg-indigo-500 text-white">
              Create Project
            </.button>
          </.form>
        </div>

        <p :if={@has_projects} class="text-center mt-4">
          <.link navigate={~p"/projects"} class="text-sm text-gray-400 hover:text-white transition-colors">
            Back to projects
          </.link>
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    default_provider = "anthropic"
    default_model = default_model_for(default_provider)
    has_projects = AgentEx.Projects.list_projects(user.id) != []

    {:ok,
     assign(socket,
       form: %{
         "name" => "",
         "description" => "",
         "root_path" => "",
         "provider" => default_provider,
         "model" => default_model
       },
       provider_options: provider_options(),
       model_options: model_select_options(default_provider),
       context_window_display: format_context_window(context_window_for(default_model)),
       has_projects: has_projects
     )}
  end

  @impl true
  def handle_event("validate", params, socket) do
    new_provider = params["provider"] || socket.assigns.form["provider"]
    provider_changed? = new_provider != socket.assigns.form["provider"]

    current_model =
      if provider_changed?,
        do: default_model_for(new_provider),
        else: params["model"] || socket.assigns.form["model"]

    form = %{
      "name" => params["name"] || "",
      "description" => params["description"] || "",
      "root_path" => params["root_path"] || "",
      "provider" => new_provider,
      "model" => current_model
    }

    socket =
      if provider_changed?,
        do: assign(socket, model_options: model_select_options(new_provider)),
        else: socket

    {:noreply,
     assign(socket,
       form: form,
       context_window_display: format_context_window(context_window_for(current_model))
     )}
  end

  def handle_event("create_project", params, socket) do
    user = socket.assigns.current_scope.user

    attrs = %{
      user_id: user.id,
      name: String.trim(params["name"] || ""),
      description: blank_to_nil(params["description"]),
      root_path: blank_to_nil(params["root_path"]),
      provider: params["provider"] || "anthropic",
      model: params["model"] || default_model_for(params["provider"] || "anthropic")
    }

    case Projects.create_project(attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project '#{project.name}' created!")
         |> redirect(to: ~p"/projects/switch/#{project.id}")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed: #{format_errors(changeset)}")}
    end
  end

  defp model_select_options(provider) do
    Enum.map(models_for_provider(provider), fn m -> {m, m} end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
