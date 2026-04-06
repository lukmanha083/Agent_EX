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

    # Orchestrator gets a minimal set of read-only tools for observation.
    # Most work should be delegated to specialist agents.
    orchestrator_tools = ~w[search_find_files search_grep editor_read system_specs]

    read_tools =
      available
      |> Enum.filter(&(AgentEx.Tool.read?(&1) and &1.name in orchestrator_tools))

    # Provider builtins — orchestrator only gets read-kind (e.g. web_search, not code_execution)
    provider_read = if provider, do: ProviderTools.read_only_tools(provider, disabled), else: []

    # Delegate tools — orchestrator dispatches work to specialist agents
    delegate_tools =
      AgentBridge.delegate_tools(user_id, project_id, model_client,
        available_tools: available,
        memory: opts[:memory]
      )

    # Orchestrator's memory note tool
    memory_tool = orchestrator_memory_tool(root_path)

    # Task planning tools — orchestrator tracks work via a task list
    run_id = Keyword.get(opts, :run_id)
    task_tools = if run_id, do: orchestrator_task_tools(run_id), else: []

    # Workflow tools — saved workflows exposed as callable tools
    workflow_tools =
      AgentEx.Workflow.Tool.workflows_as_tools(project_id,
        tools: available,
        agent_runner: opts[:agent_runner]
      )

    read_tools ++ provider_read ++ delegate_tools ++ memory_tool ++ task_tools ++ workflow_tools
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

  defp orchestrator_task_tools(run_id) do
    [
      AgentEx.Tool.new(
        name: "create_task",
        description:
          "Create a task in your plan. Use this to break work into steps before delegating. " <>
            "Each task should be a single, focused unit of work for one specialist agent.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" => "Short description of the task (what needs to be done)"
            }
          },
          "required" => ["title"]
        },
        kind: :write,
        function: fn args ->
          task = AgentEx.TaskList.create_task(run_id, args)
          {:ok, "Task ##{task.id} created: #{task.title}"}
        end
      ),
      AgentEx.Tool.new(
        name: "update_task",
        description:
          "Update a task's status and optionally record which agent handled it and the result. " <>
            "Call this after delegating to an agent to track progress.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "task_id" => %{
              "type" => "integer",
              "description" => "The task ID returned by create_task"
            },
            "status" => %{
              "type" => "string",
              "enum" => ["in_progress", "completed", "failed"],
              "description" => "New status for the task"
            },
            "agent" => %{
              "type" => "string",
              "description" => "Name of the specialist agent handling this task"
            },
            "result" => %{
              "type" => "string",
              "description" => "Brief summary of the result or error"
            }
          },
          "required" => ["task_id", "status"]
        },
        kind: :write,
        function: fn args -> execute_update_task(run_id, args) end
      ),
      AgentEx.Tool.new(
        name: "list_tasks",
        description:
          "Show all tasks in your current plan with their status. " <>
            "Use this to review progress before deciding next steps.",
        parameters: %{
          "type" => "object",
          "properties" => %{}
        },
        kind: :read,
        function: fn _args ->
          {:ok, AgentEx.TaskList.format_tasks(run_id)}
        end
      )
    ]
  end

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
      """
      You are a helpful AI assistant with read-only access to the project files.

      ## Important limitation
      This project has no specialist agents configured yet. You can:
      - Search and read files in the codebase
      - Answer questions about the code
      - Fetch web content for research
      - Save planning notes to .memory/

      You CANNOT modify files, run commands, or execute code because those actions
      require specialist agents that the user hasn't created yet.

      If the user asks you to perform a task that requires modifying files, running code,
      or any write operation, explain that they need to create at least one specialist agent
      first. Direct them to the **Agents** page in the sidebar to set up agents with the
      appropriate tools (e.g. text editor, shell, filesystem).

      Be helpful with what you CAN do — read code, explain architecture, plan tasks,
      and prepare notes so that once agents are set up, work can begin immediately.
      """
    else
      agent_descriptions =
        Enum.map_join(agents, "\n", fn a ->
          desc = a.description || summary_from_config(a)
          "- **#{a.name}**: #{desc}"
        end)

      """
      You are an AI orchestrator. Plan, delegate, synthesize — never act directly.

      ## Session startup
      Check .memory/ for plan.md and progress.md to resume previous work. If none exist, start fresh.

      ## Specialists
      #{agent_descriptions}

      ## Workflow
      1. Answer directly for questions, explanations, code snippets, advice
      2. Delegate via delegate_to_* tools ONLY for file writes, shell commands, system operations
      3. For multi-step work: create_task → delegate → update_task → list_tasks → synthesize
      4. Save progress to .memory/*.md via save_note (plan.md, progress.md, decisions.md)

      ## Rules
      - You CANNOT write files or run commands — delegate those to specialists
      - You CAN read files (editor_read, search_grep, search_find_files) for planning
      - One focused task per delegation — don't combine unrelated operations
      - Report delegation errors to user instead of retrying endlessly

      ## Missing capabilities
      If no specialist can handle a task, tell the user what's missing and suggest an agent config (name, role, model, tools). Link: [Create agent](/agents)
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

  @valid_statuses %{
    "pending" => :pending,
    "in_progress" => :in_progress,
    "completed" => :completed,
    "failed" => :failed
  }

  defp execute_update_task(run_id, args) do
    task_id = args["task_id"]

    case Map.get(@valid_statuses, args["status"]) do
      nil ->
        {:error,
         "Invalid status: #{args["status"]}. Use: pending, in_progress, completed, failed"}

      status ->
        updates = build_task_updates(status, args)

        case AgentEx.TaskList.update_task(run_id, task_id, updates) do
          {:ok, t} -> {:ok, "Task ##{t.id} updated: #{t.status} — #{t.title}"}
          {:error, :not_found} -> {:error, "Task ##{task_id} not found"}
        end
    end
  end

  defp build_task_updates(status, args) do
    base = %{status: status}
    base = if args["agent"], do: Map.put(base, :agent, args["agent"]), else: base
    if args["result"], do: Map.put(base, :result, args["result"]), else: base
  end
end
