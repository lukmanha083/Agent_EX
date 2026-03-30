defmodule AgentEx.ToolAssembler do
  @moduledoc """
  Assembles all tool sources into a unified [Tool] list for a user/project.
  Called on each message send to get the freshest tool set.

  Sources:
  1. Built-in utility tools (time, system info)
  2. HTTP API tools (from HttpToolStore)
  3. Agent delegate tools (from AgentBridge)

  Future sources (MCP, plugins) will be added here.
  """

  alias AgentEx.{AgentBridge, AgentConfig, AgentStore, ProviderTools}

  @doc """
  Assemble all tools for the chat orchestrator.
  Returns a flat list of `%Tool{}` structs including delegate tools for each agent.

  ## Options
  - `:memory` — memory opts passed to delegate sub-agents
  - `:provider` — provider string for builtin tools (e.g. "anthropic")
  - `:disabled_builtins` — list of builtin names to exclude (from user profile)
  """
  def assemble(user_id, project_id, model_client, opts \\ []) do
    available = AgentBridge.available_tools(user_id, project_id)
    provider = Keyword.get(opts, :provider)
    disabled = Keyword.get(opts, :disabled_builtins, [])
    builtins = if provider, do: ProviderTools.enabled_tools(provider, disabled), else: []

    delegate_tools =
      AgentBridge.delegate_tools(user_id, project_id, model_client,
        available_tools: available,
        memory: opts[:memory]
      )

    available ++ builtins ++ delegate_tools
  end

  @doc """
  Build the orchestrator system prompt with descriptions of available agents.
  Falls back to a simple assistant prompt when no agents are defined.
  """
  def orchestrator_prompt(user_id, project_id) do
    agents = AgentStore.list(user_id, project_id)

    if agents == [] do
      "You are a helpful AI assistant."
    else
      agent_descriptions =
        Enum.map_join(agents, "\n", fn a ->
          desc = a.description || summary_from_config(a)
          "- **#{a.name}**: #{desc}"
        end)

      """
      You are an AI assistant with access to specialist agents and tools.

      ## How to work:
      - For simple questions, answer directly using your knowledge.
      - For tasks requiring specific tools, use them directly.
      - For complex tasks, decompose into steps and delegate to specialist agents.
      - When delegating, pass clear task descriptions to each agent.
      - Each specialist runs independently with its own tools and returns a result.
      - You can call multiple agents in one turn if their work is independent.

      ## Available specialists:
      #{agent_descriptions}

      ## Pattern selection:
      - **Direct**: Simple questions — answer without tools
      - **Tool use**: Specific data needed — call the relevant tool
      - **Sequential delegation**: Task A's output feeds Task B — delegate one at a time
      - **Parallel delegation**: Independent subtasks — call multiple delegates in one turn
      """
    end
  end

  defp summary_from_config(%AgentConfig{} = config) do
    parts =
      [
        config.role,
        if(config.goal, do: "Goal: #{config.goal}"),
        if(config.system_prompt && String.length(config.system_prompt) < 100,
          do: config.system_prompt
        )
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "specialist agent"
      _ -> Enum.join(parts, ". ")
    end
  end
end
