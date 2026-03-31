defmodule AgentEx.ToolAssembler do
  @moduledoc """
  Assembles all tool sources into a unified [Tool] list for a user/project.
  Called on each message send to get the freshest tool set.

  Sources:
  1. Built-in plugin tools (filesystem, search, editor, web, system, diff)
  2. HTTP API tools (from HttpToolStore)
  3. Provider builtin tools (Anthropic web_search, code_execution, etc.)
  4. Agent delegate tools (from AgentBridge)
  """

  alias AgentEx.{AgentBridge, AgentConfig, AgentStore, ProviderTools, ToolPlugin}

  require Logger

  @builtin_plugins [
    AgentEx.Plugins.FileSystem,
    AgentEx.Plugins.ShellExec,
    AgentEx.Plugins.CodeSearch,
    AgentEx.Plugins.TextEditor,
    AgentEx.Plugins.WebFetch,
    AgentEx.Plugins.SystemInfo,
    AgentEx.Plugins.Diff
  ]

  @doc """
  Assemble tools for the chat orchestrator.

  The orchestrator does NOT get direct tool access. It only receives:
  1. Delegate tools (`delegate_to_<agent>`) — to dispatch tasks to specialist agents
  2. Provider builtins (e.g. Anthropic web_search) — for reasoning support

  Plugin tools and HTTP API tools are only available to specialist agents
  via their `tool_ids` configuration. This enforces the pattern:
  orchestrator reasons → delegates to agents → agents use tools → report back.

  ## Options
  - `:memory` — memory opts passed to delegate sub-agents
  - `:provider` — provider string for builtin tools (e.g. "anthropic")
  - `:disabled_builtins` — list of builtin names to exclude (from user profile)
  - `:root_path` — sandbox root for file-based plugins (from project)
  """
  def assemble(user_id, project_id, model_client, opts \\ []) do
    root_path = Keyword.get(opts, :root_path)
    provider = Keyword.get(opts, :provider)
    disabled = Keyword.get(opts, :disabled_builtins, [])

    # Full tool pool — specialist agents get assigned from this via tool_ids
    available = available_tools(user_id, project_id, root_path)

    # Orchestrator gets :read plugin tools only — it can observe but not act
    read_tools = Enum.filter(available, &AgentEx.Tool.read?/1)

    # Provider builtins — orchestrator only gets read-kind (e.g. web_search, not code_execution)
    provider_read = if provider, do: ProviderTools.read_only_tools(provider, disabled), else: []

    # Delegate tools — orchestrator dispatches work to specialist agents
    delegate_tools =
      AgentBridge.delegate_tools(user_id, project_id, model_client,
        available_tools: available,
        memory: opts[:memory]
      )

    # Orchestrator's memory note tool — its only write capability
    memory_tool = orchestrator_memory_tool(root_path)

    read_tools ++ provider_read ++ delegate_tools ++ memory_tool
  end

  @doc """
  Build the full pool of tools available for agent assignment.
  These are the tools that specialist agents can be given via `tool_ids`.
  The orchestrator never sees these directly.
  """
  def available_tools(user_id, project_id, root_path \\ nil) do
    plugin_tools = init_builtin_plugins(root_path)
    http_tools = AgentBridge.http_api_tools(user_id, project_id)
    plugin_tools ++ http_tools
  end

  # The orchestrator's only write tool — save/read planning notes to .md files
  # within a `.memory/` directory under the project root.
  defp orchestrator_memory_tool(nil), do: []

  defp orchestrator_memory_tool(root_path) when is_binary(root_path) and root_path != "" do
    memory_dir = Path.join(root_path, ".memory")

    [
      AgentEx.Tool.new(
        name: "save_note",
        description:
          "Save a planning note or memory to a markdown file. " <>
            "Use this to persist observations, decisions, and context across conversations. " <>
            "Files are saved in the project's .memory/ directory.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "filename" => %{
              "type" => "string",
              "description" =>
                "Filename for the note (e.g. 'plan.md', 'decisions.md'). Must end in .md"
            },
            "content" => %{
              "type" => "string",
              "description" => "Markdown content to write"
            },
            "mode" => %{
              "type" => "string",
              "enum" => ["overwrite", "append"],
              "description" =>
                "Write mode: overwrite replaces file, append adds to end (default: overwrite)"
            }
          },
          "required" => ["filename", "content"]
        },
        kind: :write,
        function: fn args ->
          filename = Map.fetch!(args, "filename")
          content = Map.fetch!(args, "content")
          mode = Map.get(args, "mode", "overwrite")

          with :ok <- validate_md_filename(filename),
               :ok <- File.mkdir_p(memory_dir) do
            file_path = Path.join(memory_dir, filename)

            write_result =
              case mode do
                "append" -> File.write(file_path, content, [:append])
                _ -> File.write(file_path, content)
              end

            case write_result do
              :ok when mode == "append" ->
                {:ok, "Appended to .memory/#{filename}"}

              :ok ->
                {:ok, "Saved .memory/#{filename}"}

              {:error, reason} ->
                {:error, "Failed to write .memory/#{filename}: #{inspect(reason)}"}
            end
          end
        end
      )
    ]
  end

  defp orchestrator_memory_tool(_), do: []

  defp validate_md_filename(filename) do
    cond do
      not String.ends_with?(filename, ".md") ->
        {:error, "Filename must end in .md"}

      String.contains?(filename, "..") ->
        {:error, "Path traversal not allowed"}

      String.contains?(filename, "/") ->
        {:error, "Subdirectories not allowed — use flat filenames"}

      true ->
        :ok
    end
  end

  @doc """
  Returns the list of built-in plugin modules.
  Used by the tools page UI to list available plugins.
  """
  def builtin_plugin_modules, do: @builtin_plugins

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
      You are an AI orchestrator. You plan, delegate, and synthesize — you do not act directly.

      ## Session startup
      1. Check `.memory/` for previous plans and progress (use search.find_files or editor.read)
      2. If files exist, read plan.md and progress.md to understand where you left off
      3. If no files exist, this is a fresh project — start planning from scratch

      ## Workflow
      1. **Observe**: Use read-only tools to understand the codebase, search files, read docs
      2. **Plan**: Break the task into steps, decide which specialist handles each step
      3. **Delegate**: Dispatch tasks to specialist agents — they have full tool access
      4. **Synthesize**: Review agent results (including their memory reports), reason over them
      5. **Save progress**: After each delegation round, update .memory/ files incrementally

      ## Memory files (.memory/)
      Use `save_note` to persist your state across sessions:
      - `plan.md` — current task breakdown and strategy
      - `progress.md` — what's done, what's pending, blockers
      - `decisions.md` — key decisions and reasoning (so future sessions understand WHY)

      Save incrementally — don't wait until the end. If the session ends unexpectedly, nothing should be lost.

      ## Available specialists:
      #{agent_descriptions}

      ## Delegation patterns:
      - **Sequential**: Task A's output feeds Task B — delegate one at a time
      - **Parallel**: Independent subtasks — call multiple delegates in one turn
      - **Iterative**: Review result, refine task, delegate again

      ## Rules:
      - You CANNOT modify files, run commands, or execute code directly
      - You CAN read files, search the codebase, and fetch web content for planning
      - You CAN save notes to .memory/*.md files
      - All modifications happen through specialist agents
      """
    end
  end

  # --- Plugin initialization ---

  defp init_builtin_plugins(nil) do
    # No root_path — only init plugins that don't require one
    init_plugins_with_config(%{})
  end

  defp init_builtin_plugins(root_path) when is_binary(root_path) and root_path != "" do
    init_plugins_with_config(%{"root_path" => root_path})
  end

  defp init_builtin_plugins(_), do: init_plugins_with_config(%{})

  defp init_plugins_with_config(base_config) do
    Enum.flat_map(@builtin_plugins, fn mod ->
      config = build_plugin_config(mod, base_config)

      case safe_init(mod, config) do
        {:ok, tools} ->
          manifest = mod.manifest()
          ToolPlugin.prefix_tools(manifest.name, tools)

        :skip ->
          []
      end
    end)
  end

  defp build_plugin_config(mod, base_config) do
    schema = mod.manifest().config_schema

    Enum.reduce(schema, base_config, fn param, acc ->
      {name, _type, _desc, opts} = normalize_param(param)
      key = Atom.to_string(name)
      optional = Keyword.get(opts, :optional, false)
      default = Keyword.get(opts, :default)

      if optional and not Map.has_key?(acc, key) and not is_nil(default) do
        Map.put(acc, key, default)
      else
        acc
      end
    end)
  end

  defp safe_init(mod, config) do
    # Check if all required config keys are present
    schema = mod.manifest().config_schema

    missing =
      Enum.any?(schema, fn param ->
        {name, _type, _desc, opts} = normalize_param(param)
        key = Atom.to_string(name)
        not Keyword.get(opts, :optional, false) and not Map.has_key?(config, key)
      end)

    if missing do
      :skip
    else
      case mod.init(config) do
        {:ok, tools} -> {:ok, tools}
        {:stateful, tools, _} -> {:ok, tools}
        _ -> :skip
      end
    end
  rescue
    e ->
      Logger.warning("ToolAssembler: failed to init #{inspect(mod)}: #{Exception.message(e)}")
      :skip
  end

  defp normalize_param({name, type, desc}), do: {name, type, desc, []}
  defp normalize_param({name, type, desc, opts}), do: {name, type, desc, opts}

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
