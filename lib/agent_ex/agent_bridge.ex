defmodule AgentEx.AgentBridge do
  @moduledoc """
  Converts AgentStore configs into delegate tools for the chat orchestrator.
  Each agent becomes a callable tool — the LLM delegates by calling it.

  Stateless module — reads AgentStore and builds tools on demand.
  """

  alias AgentEx.{AgentConfig, AgentStore, HttpTool, HttpToolStore, Pipe, ProviderTools, Tool}

  require Logger

  @doc """
  Build delegate tools for all agents in a project.
  Each agent becomes: delegate_to_<name>(task) -> runs agent's full loop -> returns result.
  """
  def delegate_tools(user_id, project_id, model_client, opts \\ []) do
    AgentStore.list(user_id, project_id)
    |> Enum.map(fn config ->
      delegate_tool_from_config(config, user_id, project_id, model_client, opts)
    end)
  end

  defp delegate_tool_from_config(%AgentConfig{} = config, user_id, project_id, model_client, opts) do
    system_message = AgentConfig.build_system_messages(config)

    system_message =
      if system_message in [nil, ""],
        do: "You are #{config.name}, a helpful AI assistant.",
        else: system_message

    agent_tools = resolve_tools(config, user_id, project_id, opts)
    builtin_tools = ProviderTools.enabled_tools(config.provider, config.disabled_builtins || [])

    pipe_agent =
      Pipe.Agent.new(
        name: config.name,
        system_message: system_message,
        tools: agent_tools ++ builtin_tools,
        intervention: resolve_intervention(config)
      )

    # Resolve context_window from agent's own model
    agent_context_window = AgentEx.ProviderHelpers.context_window_for(config.model)

    memory_opts =
      case opts[:memory] do
        %{session_id: sid} ->
          %{
            user_id: user_id,
            project_id: project_id,
            agent_id: "u#{user_id}_p#{project_id}_#{config.id}",
            session_id: sid,
            context_window: agent_context_window
          }

        _ ->
          nil
      end

    pipe_opts = if memory_opts, do: [memory: memory_opts], else: []

    Pipe.delegate_tool(config.name, pipe_agent, model_client, pipe_opts)
  end

  defp resolve_tools(%AgentConfig{tool_ids: []}, _user_id, _project_id, _opts), do: []

  defp resolve_tools(%AgentConfig{tool_ids: tool_ids}, _user_id, _project_id, opts)
       when is_list(tool_ids) do
    available = Keyword.get(opts, :available_tools, [])

    Enum.filter(available, fn %Tool{name: name} ->
      name in tool_ids
    end)
  end

  defp resolve_tools(_config, _user_id, _project_id, _opts), do: []

  defp resolve_intervention(%AgentConfig{intervention_pipeline: handlers})
       when is_list(handlers) and handlers != [] do
    Enum.flat_map(handlers, fn
      %{"id" => id} = entry -> resolve_handler(id, entry)
      %{id: id} = entry -> resolve_handler(id, entry)
      _ -> []
    end)
  end

  defp resolve_intervention(_), do: []

  defp resolve_handler("permission_handler", _entry),
    do: [AgentEx.Intervention.PermissionHandler]

  defp resolve_handler("write_gate_handler", entry) do
    allowed =
      Map.get(entry, "allowed_writes") ||
        Map.get(entry, :allowed_writes) ||
        []

    [{AgentEx.Intervention.WriteGateHandler, allowed_writes: allowed}]
  end

  defp resolve_handler("log_handler", _entry),
    do: [AgentEx.Intervention.LogHandler]

  defp resolve_handler(unknown_id, _entry) do
    Logger.warning("AgentBridge: unknown intervention handler '#{unknown_id}', skipping")
    []
  end

  @doc """
  Build the list of non-delegate tools available to agents in a project.
  Includes plugin tools (via ToolAssembler) and HTTP API tools.
  """
  def available_tools(user_id, project_id) do
    http_api_tools(user_id, project_id)
  end

  @doc """
  Build the list of HTTP API tools for a project.
  """
  def http_api_tools(user_id, project_id) do
    HttpToolStore.list(user_id, project_id)
    |> Enum.map(&HttpTool.to_tool/1)
  end
end
