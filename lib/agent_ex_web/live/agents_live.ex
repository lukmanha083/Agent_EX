defmodule AgentExWeb.AgentsLive do
  use AgentExWeb, :live_view

  alias AgentEx.{AgentConfig, AgentStore}

  import AgentExWeb.AgentComponents
  import AgentExWeb.ProviderHelpers,
    only: [default_model_for: 1, provider_options: 0, models_for_provider: 1]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.current_project
    agents = AgentStore.list(user.id, project.id)
    default_provider = "openai"

    {:ok,
     assign(socket,
       project: project,
       agents: agents,
       editing: nil,
       show_editor: false,
       form: empty_form(),
       intervention_pipeline: [],
       sandbox: %{},
       selected_provider: default_provider,
       provider_options: provider_options(),
       model_options: model_select_options(default_provider)
     )}
  end

  # -- Agent CRUD events --

  @impl true
  def handle_event("new_agent", _params, socket) do
    default_provider = "openai"

    {:noreply,
     assign(socket,
       editing: nil,
       show_editor: true,
       form: empty_form(),
       intervention_pipeline: [],
       sandbox: %{},
       selected_provider: default_provider,
       model_options: model_select_options(default_provider)
     )}
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.project

    case AgentStore.get(user.id, project.id, id) do
      {:ok, agent} ->
        {:noreply,
         assign(socket,
           editing: agent,
           show_editor: true,
           form: agent_to_form(agent),
           intervention_pipeline: agent.intervention_pipeline || [],
           sandbox: agent.sandbox || %{},
           selected_provider: agent.provider,
           model_options: model_select_options(agent.provider)
         )}

      :not_found ->
        {:noreply, put_flash(socket, :error, "Agent not found")}
    end
  end

  def handle_event("close_editor", _params, socket) do
    {:noreply, assign(socket, show_editor: false, editing: nil)}
  end

  def handle_event("validate_agent", params, socket) do
    new_provider = params["provider"] || socket.assigns.selected_provider
    provider_changed? = new_provider != socket.assigns.selected_provider

    form = merge_form_params(socket.assigns.form, params, new_provider, provider_changed?)

    socket =
      if provider_changed? do
        assign(socket,
          selected_provider: new_provider,
          model_options: model_select_options(new_provider)
        )
      else
        socket
      end

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save_agent", params, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.project

    attrs =
      form_to_attrs(params, socket.assigns.intervention_pipeline, socket.assigns.sandbox)

    config =
      if socket.assigns.editing do
        AgentConfig.update(socket.assigns.editing, attrs)
      else
        AgentConfig.new(attrs |> Map.put(:user_id, user.id) |> Map.put(:project_id, project.id))
      end

    case AgentStore.save(config) do
      {:ok, _config} ->
        agents = AgentStore.list(user.id, project.id)

        {:noreply,
         socket
         |> assign(agents: agents, show_editor: false, editing: nil)
         |> put_flash(:info, if(socket.assigns.editing, do: "Agent updated", else: "Agent created"))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save agent: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.project
    AgentStore.delete(user.id, project.id, id)
    agents = AgentStore.list(user.id, project.id)
    {:noreply, assign(socket, agents: agents)}
  end

  # -- Intervention pipeline events --

  def handle_event("add_handler", %{"id" => id}, socket) do
    pipeline = socket.assigns.intervention_pipeline

    if Enum.any?(pipeline, &(&1["id"] == id)) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, intervention_pipeline: pipeline ++ [%{"id" => id}])}
    end
  end

  def handle_event("remove_handler", %{"id" => id}, socket) do
    pipeline = Enum.reject(socket.assigns.intervention_pipeline, &(&1["id"] == id))
    {:noreply, assign(socket, intervention_pipeline: pipeline)}
  end

  def handle_event("reorder_pipeline", %{"ids" => ids}, socket) do
    old = socket.assigns.intervention_pipeline
    lookup = Map.new(old, &{&1["id"], &1})
    reordered = Enum.map(ids, &(lookup[&1] || %{"id" => &1}))
    {:noreply, assign(socket, intervention_pipeline: reordered)}
  end

  # -- WriteGateHandler allowlist events --

  def handle_event("add_allowed_write", %{"value" => raw}, socket) do
    tools =
      raw
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if tools == [] do
      {:noreply, socket}
    else
      pipeline = update_write_gate(socket.assigns.intervention_pipeline, fn current ->
        Enum.uniq(current ++ tools)
      end)

      {:noreply, assign(socket, intervention_pipeline: pipeline)}
    end
  end

  def handle_event("remove_allowed_write", %{"tool" => tool}, socket) do
    pipeline = update_write_gate(socket.assigns.intervention_pipeline, fn current ->
      Enum.reject(current, &(&1 == tool))
    end)

    {:noreply, assign(socket, intervention_pipeline: pipeline)}
  end

  # -- Sandbox events --

  def handle_event("add_disallowed_command", %{"value" => raw}, socket) do
    cmds =
      raw
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if cmds == [] do
      {:noreply, socket}
    else
      current = socket.assigns.sandbox["disallowed_commands"] || []
      sandbox = Map.put(socket.assigns.sandbox, "disallowed_commands", Enum.uniq(current ++ cmds))
      {:noreply, assign(socket, sandbox: sandbox)}
    end
  end

  def handle_event("remove_disallowed_command", %{"cmd" => cmd}, socket) do
    current = socket.assigns.sandbox["disallowed_commands"] || []
    sandbox = Map.put(socket.assigns.sandbox, "disallowed_commands", Enum.reject(current, &(&1 == cmd)))
    {:noreply, assign(socket, sandbox: sandbox)}
  end

  # -- Private helpers --

  defp update_write_gate(pipeline, update_fn) do
    Enum.map(pipeline, fn
      %{"id" => "write_gate_handler"} = entry ->
        current = entry["allowed_writes"] || []
        Map.put(entry, "allowed_writes", update_fn.(current))

      other ->
        other
    end)
  end

  defp empty_form do
    %{
      "name" => "",
      "description" => "",
      "system_prompt" => "You are a helpful AI assistant.",
      "provider" => "openai",
      "model" => "gpt-4o-mini"
    }
  end

  defp agent_to_form(agent) do
    %{
      "name" => agent.name,
      "description" => agent.description || "",
      "system_prompt" => agent.system_prompt,
      "provider" => agent.provider,
      "model" => agent.model
    }
  end

  defp form_to_attrs(params, intervention_pipeline, sandbox) do
    %{
      name: String.trim(params["name"] || ""),
      description: blank_to_nil(params["description"]),
      system_prompt: params["system_prompt"] || "You are a helpful AI assistant.",
      provider: params["provider"] || "openai",
      model: params["model"] || default_model_for(params["provider"] || "openai"),
      tool_ids: [],
      intervention_pipeline: intervention_pipeline,
      sandbox: sandbox
    }
  end

  defp merge_form_params(form, params, provider, provider_changed?) do
    model = if provider_changed?, do: default_model_for(provider), else: params["model"] || ""

    Map.merge(form, %{
      "name" => params["name"] || "",
      "description" => params["description"] || "",
      "system_prompt" => params["system_prompt"] || "",
      "provider" => provider,
      "model" => model
    })
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
end
