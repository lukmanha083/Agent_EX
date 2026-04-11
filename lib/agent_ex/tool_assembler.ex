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

  alias AgentEx.{AgentBridge, AgentConfig, AgentStore, Message, ModelClient, ProviderTools, Tool, ToolPlugin}
  alias AgentEx.EventLoop.Event
  alias AgentEx.MCP.Servers, as: McpServers
  alias AgentEx.Plugins.{AskUser, Todo}

  require Logger

  @builtin_plugins [
    AgentEx.Plugins.FileSystem,
    AgentEx.Plugins.ShellExec,
    AgentEx.Plugins.CodeSearch,
    AgentEx.Plugins.TextEditor,
    AgentEx.Plugins.WebFetch,
    AgentEx.Plugins.SystemInfo,
    AgentEx.Plugins.Diff,
    AgentEx.Plugins.Browser
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
    run_id = Keyword.get(opts, :run_id)
    available = available_tools(user_id, project_id, root_path, run_id, model_client)

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
        run_id: opts[:run_id],
        memory: opts[:memory]
      )

    # Orchestrator's memory note tool
    memory_tool = orchestrator_memory_tool(root_path)

    # Task planning tools — orchestrator tracks work via a task list
    task_tools = if run_id, do: orchestrator_task_tools(run_id), else: []

    # Workflow tools — saved workflows exposed as callable tools
    workflow_tools =
      AgentEx.Workflow.Tool.workflows_as_tools(project_id,
        tools: available,
        agent_runner: opts[:agent_runner]
      )

    # AskUser tool — allows orchestrator to ask the user a question via chat
    ask_user_tools = if run_id, do: ask_user_tool(run_id), else: []

    read_tools ++
      provider_read ++
      delegate_tools ++
      memory_tool ++ task_tools ++ workflow_tools ++ ask_user_tools
  end

  @doc "Build MCP server configs for server-side execution (Anthropic API)."
  def mcp_servers(project_id) do
    McpServers.build_api_config(project_id)
  end

  @doc """
  Build the full pool of tools available for agent assignment.
  These are the tools that specialist agents can be given via `tool_ids`.
  The orchestrator never sees these directly.
  """
  def available_tools(user_id, project_id, root_path \\ nil, run_id \\ nil, model_client \\ nil) do
    plugin_tools = init_builtin_plugins(root_path)
    http_tools = AgentBridge.http_api_tools(user_id, project_id)
    todo = if run_id, do: todo_tools(run_id), else: []
    advisor = if model_client, do: [advisor_tool(model_client)], else: []
    plugin_tools ++ http_tools ++ todo ++ advisor
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
        description: "Create a task in your plan. Break work into steps before delegating.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" => "Short description of the task"
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
        description: "Update a task's status after delegation completes.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "task_id" => %{"type" => "integer", "description" => "The task ID"},
            "status" => %{
              "type" => "string",
              "enum" => ["in_progress", "completed", "failed"],
              "description" => "New status"
            },
            "result" => %{
              "type" => "string",
              "description" => "Brief summary of the result"
            }
          },
          "required" => ["task_id", "status"]
        },
        kind: :write,
        function: fn args -> execute_update_task(run_id, args) end
      ),
      AgentEx.Tool.new(
        name: "list_tasks",
        description: "Show all tasks with their status.",
        parameters: %{"type" => "object", "properties" => %{}},
        kind: :read,
        function: fn _args -> {:ok, AgentEx.TaskList.format_tasks(run_id)} end
      )
    ]
  end

  @valid_statuses %{
    "in_progress" => :in_progress,
    "completed" => :completed,
    "failed" => :failed
  }

  defp execute_update_task(run_id, args) do
    case Map.get(@valid_statuses, args["status"]) do
      nil ->
        {:error, "Invalid status: #{args["status"]}"}

      status ->
        updates = %{status: status}
        updates = if args["result"], do: Map.put(updates, :result, args["result"]), else: updates

        case AgentEx.TaskList.update_task(run_id, args["task_id"], updates) do
          {:ok, t} -> {:ok, "Task ##{t.id} updated: #{t.status} — #{t.title}"}
          {:error, :not_found} -> {:error, "Task ##{args["task_id"]} not found"}
        end
    end
  end

  @ask_user_timeout 300_000

  defp ask_user_tool(run_id) do
    case AskUser.init(%{
           "handler" => fn question ->
             caller = self()

             Phoenix.PubSub.broadcast(
               AgentEx.PubSub,
               "run:#{run_id}",
               Event.new(:question_asked, run_id, %{question: question, reply_to: caller})
             )

             receive do
               {:user_answer, answer} -> {:ok, answer}
             after
               @ask_user_timeout -> {:error, "No answer received within 5 minutes"}
             end
           end
         }) do
      {:ok, tools} -> ToolPlugin.prefix_tools("ask_user", tools)
      _ -> []
    end
  end

  defp todo_tools(run_id) do
    case Todo.init(%{}) do
      {:stateful, tools, child_spec} ->
        case DynamicSupervisor.start_child(AgentEx.PluginSupervisor, child_spec) do
          {:ok, _pid} ->
            tools
            |> ToolPlugin.prefix_tools("todo")
            |> Enum.map(&broadcast_todo_writes(&1, run_id))

          {:error, reason} ->
            Logger.warning("ToolAssembler: failed to start Todo server: #{inspect(reason)}")
            []
        end

      _ ->
        []
    end
  end

  defp broadcast_todo_writes(%Tool{kind: :read} = tool, _run_id), do: tool

  defp broadcast_todo_writes(%Tool{kind: :write} = tool, run_id) do
    original_fn = tool.function

    %{
      tool
      | function: fn args ->
          result = original_fn.(args)

          case result do
            {:ok, msg} ->
              broadcast(run_id, :todo_updated, %{message: msg})
              result

            _ ->
              result
          end
        end
    }
  end

  @advisor_system """
  You are a senior technical advisor. A specialist agent is asking for your guidance.
  Give concise, actionable advice. Focus on architecture decisions, best practices,
  and project-specific context. Be direct — the agent will act on your advice immediately.
  """

  defp advisor_tool(%ModelClient{} = client) do
    Tool.new(
      name: "ask_advisor",
      description:
        "Ask the orchestrator for technical guidance when unsure about approach, " <>
          "architecture, or implementation decisions. Use this before making big " <>
          "decisions — not for trivial questions.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "question" => %{
            "type" => "string",
            "description" => "Your technical question or decision you need guidance on"
          }
        },
        "required" => ["question"]
      },
      kind: :read,
      function: fn %{"question" => question} ->
        messages = [
          Message.system(@advisor_system),
          Message.user(question)
        ]

        case ModelClient.create(client, messages, max_tokens: 1024) do
          {:ok, response} -> {:ok, response.content}
          {:error, reason} -> {:error, "Advisor unavailable: #{inspect(reason)}"}
        end
      end
    )
  end

  defp broadcast(run_id, type, data) do
    event = Event.new(type, run_id, data)
    Phoenix.PubSub.broadcast(AgentEx.PubSub, "run:#{run_id}", event)
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
    user_agents = AgentStore.list(user_id, project_id)
    system_agents = AgentStore.list_system()
    agents = Enum.uniq_by(user_agents ++ system_agents, & &1.name)

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
      You are an AI orchestrator. You reason, plan, delegate, and synthesize — never act directly.

      ## Specialists
      #{agent_descriptions}

      ## How you work
      1. Reason about the user's request — what needs to be done and in what order
      2. Break it into tasks with create_task — one task per unit of work
      3. Delegate each task to the best specialist — include clear instructions
      4. Track progress with update_task after each delegation completes
      5. If a specialist reports failures (test failures, review issues), reason about
         what went wrong and delegate a fix to the appropriate specialist
      6. Synthesize the final result when all tasks are done

      ## Delegation principles
      - Tell specialists to use filesystem_write_file for creating/modifying files
      - Tell specialists to verify their work with shell_run_command
      - Include the WHAT and WHY in delegation — the specialist knows HOW
      - The user expects working files on disk, not code displayed in chat

      ## Answer directly (no delegation) for
      Greetings, factual questions, code explanations, clarifying questions.

      ## Missing capabilities
      If no specialist can handle a task, tell the user: [Create agent](/agents)
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
