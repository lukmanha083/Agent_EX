defmodule AgentExWeb.AgentsLive do
  use AgentExWeb, :live_view

  alias AgentEx.{AgentConfig, AgentStore}

  import AgentExWeb.AgentComponents

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
    project = socket.assigns[:current_project]

    if is_nil(project) do
      {:ok,
       socket
       |> put_flash(:error, "No project available. Please create one first.")
       |> redirect(to: ~p"/projects")}
    else
      agents = AgentStore.list(user.id, project.id)
      default_provider = "openai"
      default_model = default_model_for(default_provider)

      {:ok,
       assign(socket,
         project: project,
         agents: agents,
         editing: nil,
         show_editor: false,
         show_import: false,
         form: empty_form(),
         intervention_pipeline: [],
         sandbox: %{},
         disabled_builtins: [],
         selected_provider: default_provider,
         provider_options: provider_options(),
         model_options: model_select_options(default_provider),
         context_window_display: format_context_window(context_window_for(default_model))
       )}
    end
  end

  # -- Agent CRUD events --

  @impl true
  def handle_event("new_agent", _params, socket) do
    default_provider = "openai"
    default_model = default_model_for(default_provider)

    {:noreply,
     assign(socket,
       editing: nil,
       show_editor: true,
       show_import: false,
       form: empty_form(),
       intervention_pipeline: [],
       sandbox: %{},
       disabled_builtins: [],
       selected_provider: default_provider,
       model_options: model_select_options(default_provider),
       context_window_display: format_context_window(context_window_for(default_model))
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
           show_import: false,
           form: agent_to_form(agent),
           intervention_pipeline: agent.intervention_pipeline || [],
           sandbox: agent.sandbox || %{},
           disabled_builtins: agent.disabled_builtins || [],
           selected_provider: agent.provider,
           model_options: model_select_options(agent.provider),
           context_window_display: format_context_window(context_window_for(agent.model))
         )}

      :not_found ->
        {:noreply, put_flash(socket, :error, "Agent not found")}
    end
  end

  def handle_event("close_editor", _params, socket) do
    {:noreply, assign(socket, show_editor: false, editing: nil)}
  end

  # -- Import JSON events --

  @max_import_size 65_536

  def handle_event("show_import", _params, socket) do
    {:noreply, assign(socket, show_import: true, show_editor: false)}
  end

  def handle_event("close_import", _params, socket) do
    {:noreply, assign(socket, show_import: false)}
  end

  def handle_event("import_agent", %{"json_content" => json_content}, socket)
      when byte_size(json_content) > @max_import_size do
    {:noreply, put_flash(socket, :error, "JSON too large (max 64 KB)")}
  end

  def handle_event("import_agent", %{"json_content" => json_content}, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.project

    case Jason.decode(json_content) do
      {:ok, attrs} when is_map(attrs) ->
        config = AgentConfig.from_map(attrs, user_id: user.id, project_id: project.id)

        case AgentStore.save(config) do
          {:ok, _config} ->
            agents = AgentStore.list(user.id, project.id)

            {:noreply,
             socket
             |> assign(agents: agents, show_import: false)
             |> put_flash(:info, "Agent imported: #{config.name}")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to save imported agent: #{inspect(reason)}")}
        end

      {:ok, _} ->
        {:noreply, put_flash(socket, :error, "JSON must be an object, not an array or primitive")}

      {:error, %Jason.DecodeError{} = err} ->
        {:noreply, put_flash(socket, :error, "Invalid JSON: #{Exception.message(err)}")}
    end
  rescue
    e in ArgumentError ->
      {:noreply, put_flash(socket, :error, Exception.message(e))}
  end

  def handle_event("validate_agent", params, socket) do
    new_provider = params["provider"] || socket.assigns.selected_provider
    provider_changed? = new_provider != socket.assigns.selected_provider

    form = merge_form_params(socket.assigns.form, params, new_provider, provider_changed?)

    current_model =
      if provider_changed?,
        do: default_model_for(new_provider),
        else: params["model"] || form["model"] || ""

    socket =
      if provider_changed? do
        assign(socket,
          selected_provider: new_provider,
          model_options: model_select_options(new_provider),
          disabled_builtins: []
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

  def handle_event("save_agent", params, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.project

    attrs =
      form_to_attrs(
        params,
        socket.assigns.intervention_pipeline,
        socket.assigns.sandbox,
        socket.assigns.disabled_builtins
      )

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
         |> put_flash(
           :info,
           if(socket.assigns.editing, do: "Agent updated", else: "Agent created")
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save agent: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.project

    case AgentStore.delete(user.id, project.id, id) do
      :ok ->
        agents = AgentStore.list(user.id, project.id)

        {:noreply,
         socket
         |> assign(agents: agents)
         |> put_flash(:info, "Agent deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete agent: #{inspect(reason)}")}
    end
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

    reordered =
      ids
      |> Enum.filter(&Map.has_key?(lookup, &1))
      |> Enum.map(&lookup[&1])

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
      pipeline =
        update_write_gate(socket.assigns.intervention_pipeline, fn current ->
          Enum.uniq(current ++ tools)
        end)

      {:noreply, assign(socket, intervention_pipeline: pipeline)}
    end
  end

  def handle_event("remove_allowed_write", %{"tool" => tool}, socket) do
    pipeline =
      update_write_gate(socket.assigns.intervention_pipeline, fn current ->
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

    sandbox =
      Map.put(socket.assigns.sandbox, "disallowed_commands", Enum.reject(current, &(&1 == cmd)))

    {:noreply, assign(socket, sandbox: sandbox)}
  end

  # -- Builtin tool toggle events --

  def handle_event("disable_builtin", %{"name" => name}, socket) do
    disabled = Enum.uniq([name | socket.assigns.disabled_builtins])
    {:noreply, assign(socket, disabled_builtins: disabled)}
  end

  def handle_event("enable_builtin", %{"name" => name}, socket) do
    disabled = Enum.reject(socket.assigns.disabled_builtins, &(&1 == name))
    {:noreply, assign(socket, disabled_builtins: disabled)}
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

  @form_fields ~w(name description role expertise personality goal success_criteria constraints scope tool_guidance output_format system_prompt provider model)

  defp empty_form do
    Map.new(@form_fields, &{&1, ""})
    |> Map.merge(%{"provider" => "openai", "model" => "gpt-4o-mini"})
  end

  defp agent_to_form(agent) do
    string_fields =
      ~w(name description role personality goal success_criteria scope tool_guidance output_format system_prompt provider model)

    base =
      Map.new(string_fields, fn f -> {f, Map.get(agent, String.to_existing_atom(f)) || ""} end)

    Map.merge(base, %{
      "expertise" => Enum.join(agent.expertise || [], ", "),
      "constraints" => Enum.join(agent.constraints || [], "\n")
    })
  end

  defp form_to_attrs(params, intervention_pipeline, sandbox, disabled_builtins) do
    %{
      name: String.trim(params["name"] || ""),
      description: blank_to_nil(params["description"]),
      role: blank_to_nil(params["role"]),
      expertise: split_list(params["expertise"], ","),
      personality: blank_to_nil(params["personality"]),
      goal: blank_to_nil(params["goal"]),
      success_criteria: blank_to_nil(params["success_criteria"]),
      constraints: split_list(params["constraints"], "\n"),
      scope: blank_to_nil(params["scope"]),
      tool_guidance: blank_to_nil(params["tool_guidance"]),
      tool_examples: [],
      output_format: blank_to_nil(params["output_format"]),
      system_prompt: blank_to_nil(params["system_prompt"]),
      provider: params["provider"] || "openai",
      model: params["model"] || default_model_for(params["provider"] || "openai"),
      context_window:
        context_window_for(params["model"] || default_model_for(params["provider"] || "openai")),
      disabled_builtins: disabled_builtins,
      tool_ids: [],
      intervention_pipeline: intervention_pipeline,
      sandbox: sandbox
    }
  end

  defp merge_form_params(form, params, provider, provider_changed?) do
    model = if provider_changed?, do: default_model_for(provider), else: params["model"] || ""

    Enum.reduce(@form_fields, form, fn field, acc ->
      value =
        case field do
          "provider" -> provider
          "model" -> model
          _ -> params[field] || ""
        end

      Map.put(acc, field, value)
    end)
  end

  defp split_list(nil, _sep), do: []

  defp split_list(str, sep) when is_binary(str) do
    str |> String.split(sep, trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
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
