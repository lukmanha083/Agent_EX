defmodule AgentEx.Pipe do
  @moduledoc """
  Pipe-based orchestration — function composition for AI.

  Tools, agents, and teams are composable transforms. Each pipe stage
  gets clean input and produces clean output, with isolated conversations.

  ## Patterns

  ### Static pipeline (developer-defined)

      "Analyze AAPL stock"
      |> Pipe.through(researcher, client)
      |> Pipe.through(analyst, client)
      |> Pipe.through(writer, client)

  ### Dynamic pipeline (LLM-composed via delegate tools)

      orchestrator = Pipe.Agent.new(
        name: "orchestrator",
        system_message: "You are a workflow planner.",
        tools: [
          Pipe.delegate_tool("researcher", researcher, client),
          Pipe.delegate_tool("analyst", analyst, client)
        ]
      )
      "Analyze AAPL" |> Pipe.through(orchestrator, client)

  ### Parallel fan-out + merge

      "Research OTP patterns"
      |> Pipe.fan_out([web_researcher, code_reader], client)
      |> Pipe.merge(lead_researcher, client)
  """

  alias AgentEx.{Memory, Message, ModelClient, Sensing, Tool, ToolAgent}

  require Logger

  defmodule Agent do
    @moduledoc "Agent definition for pipe stages."
    @enforce_keys [:name, :system_message]
    defstruct [
      :name,
      :system_message,
      tools: [],
      plugins: [],
      intervention: [],
      max_iterations: 10
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            system_message: String.t(),
            tools: [Tool.t()],
            plugins: [module()],
            intervention: [AgentEx.Intervention.handler()],
            max_iterations: pos_integer()
          }

    def new(opts), do: struct!(__MODULE__, opts)
  end

  @doc """
  Pass input through an agent. Returns the agent's text response.

  Runs an isolated ToolCallerLoop — the agent gets a fresh conversation
  with only the system message and the input as a user message.

  ## Options
  - `:memory` — `%{session_id: "..."}` to enable memory (agent_id derived from agent.name)
  - `:model_fn` — override for `ModelClient.create/3` (useful for testing).
    Signature: `(messages, tools) -> {:ok, Message.t()} | {:error, term()}`
  """
  @spec through(String.t(), Agent.t(), ModelClient.t() | nil, keyword()) :: String.t()
  def through(input, %Agent{} = agent, model_client, opts \\ []) do
    messages = [
      Message.system(agent.system_message),
      Message.user(input)
    ]

    tools = agent.tools
    tools_map = Map.new(tools, fn %Tool{name: name} = t -> {name, t} end)

    {:ok, tool_agent} = ToolAgent.start_link(tools: tools)

    memory_opts =
      case opts[:memory] do
        %{user_id: uid, project_id: pid, agent_id: aid, session_id: sid} ->
          %{user_id: uid, project_id: pid, agent_id: aid, session_id: sid}

        %{user_id: uid, project_id: pid, session_id: sid} ->
          %{user_id: uid, project_id: pid, agent_id: agent.name, session_id: sid}

        _ ->
          nil
      end

    ctx = %{
      tool_agent: tool_agent,
      model_client: model_client,
      model_fn: Keyword.get(opts, :model_fn),
      tools: tools,
      tools_map: tools_map,
      intervention: agent.intervention,
      max_iterations: agent.max_iterations
    }

    try do
      run_loop(ctx, messages, memory_opts)
    after
      GenServer.stop(tool_agent)
    end
  end

  @doc """
  Pass input through a tool. Returns the tool's output as string.

  For tool-level chaining within a pipe, the input is passed as the
  first argument value or as the full args map.
  """
  @spec tool(String.t() | map(), Tool.t()) :: String.t()
  def tool(input, %Tool{} = t) when is_binary(input) do
    # Determine the first required parameter name from the schema
    param_name =
      case t.parameters do
        %{"required" => [first | _]} -> first
        _ -> "input"
      end

    case Tool.execute(t, %{param_name => input}) do
      {:ok, value} -> to_string(value)
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  end

  def tool(input, %Tool{} = t) when is_map(input) do
    case Tool.execute(t, input) do
      {:ok, value} -> to_string(value)
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  end

  @doc """
  Fan out input to multiple agents in parallel. Returns list of results.

  Each agent runs in its own isolated ToolCallerLoop via `Task.async_stream`.
  """
  @spec fan_out(String.t(), [Agent.t()], ModelClient.t(), keyword()) :: [String.t()]
  def fan_out(input, agents, model_client, opts \\ []) do
    agents
    |> Task.async_stream(
      fn agent -> through(input, agent, model_client, opts) end,
      timeout: Keyword.get(opts, :timeout, 120_000),
      ordered: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> "Error: agent failed — #{inspect(reason)}"
    end)
  end

  @doc """
  Merge multiple results through a consolidating agent.

  Formats the results as numbered sections and passes them as input
  to the consolidator agent.
  """
  @spec merge([String.t()], Agent.t(), ModelClient.t(), keyword()) :: String.t()
  def merge(results, %Agent{} = consolidator, model_client, opts \\ []) do
    formatted =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {result, idx} ->
        "--- Source #{idx} ---\n#{result}"
      end)

    through(formatted, consolidator, model_client, opts)
  end

  @doc """
  Route input through a function that selects the next agent.

  The router function receives the input and returns the agent to use.
  """
  @spec route(String.t(), (String.t() -> Agent.t()), ModelClient.t(), keyword()) :: String.t()
  def route(input, router_fn, model_client, opts \\ []) when is_function(router_fn, 1) do
    agent = router_fn.(input)
    through(input, agent, model_client, opts)
  end

  @doc """
  Build a delegate tool — wraps a sub-agent as a tool for orchestrator agents.

  When the LLM calls this tool, it runs a full isolated ToolCallerLoop
  for the sub-agent and returns the result as the tool response.
  """
  @spec delegate_tool(String.t(), Agent.t(), ModelClient.t(), keyword()) :: Tool.t()
  def delegate_tool(name, %Agent{} = agent, model_client, opts \\ []) do
    Tool.new(
      name: "delegate_to_#{name}",
      description: "Delegate a task to #{name}. #{agent.system_message}",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{"type" => "string", "description" => "The task to delegate to #{name}"}
        },
        "required" => ["task"]
      },
      function: fn %{"task" => task} ->
        result = through(task, agent, model_client, opts)
        report = build_memory_report(name, opts)
        {:ok, result <> report}
      end
    )
  end

  defp build_memory_report(agent_name, opts) do
    case opts[:memory] do
      %{user_id: uid, project_id: pid, session_id: sid} ->
        agent_id = "u#{uid}_p#{pid}_#{agent_name}"

        Memory.ContextBuilder.build_report(uid, pid, agent_id, sid,
          semantic_query: ""
        )

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  # -- Private: loop execution --

  defp run_loop(ctx, messages, memory_opts) do
    messages = maybe_inject_memory(messages, memory_opts)
    ctx = Map.put(ctx, :input_messages, messages)

    case think(ctx, messages) do
      {:ok, response} -> do_loop(ctx, [response], 0)
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  end

  defp do_loop(ctx, generated, iteration) do
    last = List.last(generated)

    cond do
      not has_tool_calls?(last) ->
        last.content || ""

      iteration >= ctx.max_iterations ->
        Logger.warning("Pipe: hit max_iterations (#{ctx.max_iterations})")
        last.content || ""

      true ->
        {:ok, result_message, _observations} =
          Sensing.sense(ctx.tool_agent, last.tool_calls,
            intervention: ctx.intervention,
            tools_map: ctx.tools_map,
            intervention_context: %{iteration: iteration, generated_messages: generated}
          )

        all_messages = ctx.input_messages ++ generated ++ [result_message]

        case think(ctx, all_messages) do
          {:ok, response} ->
            do_loop(ctx, generated ++ [result_message, response], iteration + 1)

          {:error, reason} ->
            "Error: #{inspect(reason)}"
        end
    end
  end

  # Dispatch to model_fn override or ModelClient.create
  defp think(%{model_fn: fun, tools: tools}, messages) when is_function(fun, 2) do
    fun.(messages, tools)
  end

  defp think(%{model_client: client, tools: tools}, messages) do
    ModelClient.create(client, messages, tools: tools)
  end

  defp has_tool_calls?(%Message{tool_calls: calls}) when is_list(calls) and calls != [], do: true
  defp has_tool_calls?(_), do: false

  defp maybe_inject_memory(messages, nil), do: messages

  defp maybe_inject_memory(messages, memory_opts) do
    %{user_id: user_id, project_id: project_id, agent_id: agent_id, session_id: session_id} =
      memory_opts

    context_window = Map.get(memory_opts, :context_window)

    Memory.inject_memory_context(messages, user_id, project_id, agent_id, session_id,
      context_window: context_window
    )
  end
end
