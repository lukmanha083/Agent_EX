defmodule AgentExWeb.AgentsLive do
  use AgentExWeb, :live_view

  alias AgentEx.{AgentConfig, AgentStore}

  import AgentExWeb.AgentComponents
  import AgentExWeb.ProviderHelpers,
    only: [default_model_for: 1, provider_options: 0, models_for_provider: 1]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    agents = AgentStore.list(user.id)
    default_provider = "openai"

    {:ok,
     assign(socket,
       agents: agents,
       editing: nil,
       show_editor: false,
       form: empty_form(),
       selected_provider: default_provider,
       provider_options: provider_options(),
       model_options: model_select_options(default_provider)
     )}
  end

  @impl true
  def handle_event("new_agent", _params, socket) do
    default_provider = "openai"

    {:noreply,
     assign(socket,
       editing: nil,
       show_editor: true,
       form: empty_form(),
       selected_provider: default_provider,
       model_options: model_select_options(default_provider)
     )}
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case AgentStore.get(user.id, id) do
      {:ok, agent} ->
        {:noreply,
         assign(socket,
           editing: agent,
           show_editor: true,
           form: agent_to_form(agent),
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

    config =
      if socket.assigns.editing do
        AgentConfig.update(socket.assigns.editing, form_to_attrs(params))
      else
        AgentConfig.new(Map.put(form_to_attrs(params), :user_id, user.id))
      end

    case AgentStore.save(config) do
      {:ok, _config} ->
        agents = AgentStore.list(user.id)

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
    AgentStore.delete(user.id, id)
    agents = AgentStore.list(user.id)
    {:noreply, assign(socket, agents: agents)}
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

  defp form_to_attrs(params) do
    %{
      name: String.trim(params["name"] || ""),
      description: blank_to_nil(params["description"]),
      system_prompt: params["system_prompt"] || "You are a helpful AI assistant.",
      provider: params["provider"] || "openai",
      model: params["model"] || default_model_for(params["provider"] || "openai"),
      tool_ids: [],
      intervention_pipeline: []
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
