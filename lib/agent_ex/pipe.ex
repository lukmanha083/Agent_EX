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

  alias AgentEx.{Memory, Message, ModelClient, Orchestrator, Sensing, Specialist, Tool, ToolAgent}

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
  def through(input, agent, model_client, opts \\ [])

  # Handle chaining from a previous through() that returned {text, usage}
  def through({text, _prev_usage}, %Agent{} = agent, model_client, opts) do
    through(text, agent, model_client, opts)
  end

  def through(input, %Agent{} = agent, model_client, opts) when is_binary(input) do
    messages = [
      Message.system(agent.system_message),
      Message.user(input)
    ]

    tools = agent.tools
    tools_map = Map.new(tools, fn %Tool{name: name} = t -> {name, t} end)

    {:ok, tool_agent} = ToolAgent.start_link(tools: tools)

    memory_opts =
      case opts[:memory] do
        %{user_id: uid, project_id: pid, agent_id: aid, session_id: sid} = mem ->
          %{
            user_id: uid,
            project_id: pid,
            agent_id: aid,
            session_id: sid,
            context_window: Map.get(mem, :context_window)
          }

        %{user_id: uid, project_id: pid, session_id: sid} = mem ->
          %{
            user_id: uid,
            project_id: pid,
            agent_id: agent.name,
            session_id: sid,
            context_window: Map.get(mem, :context_window)
          }

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

  @doc "Extract the text result from through/4 (for backwards compatibility)."
  def through_result({text, _usage}), do: text
  def through_result(text) when is_binary(text), do: text

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
      {:ok, {result, _usage}} -> result
      {:ok, result} when is_binary(result) -> result
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
        {result, usage} = through(task, agent, model_client, opts)

        if model_client do
          Logger.info(
            "Pipe.delegate_tool: agent=#{name} usage=#{inspect(usage)} project_id=#{inspect(model_client.project_id)}"
          )

          if model_client.project_id && (usage.input_tokens > 0 or usage.output_tokens > 0) do
            AgentEx.Budget.record_usage(%{
              project_id: model_client.project_id,
              provider: to_string(model_client.provider),
              model: model_client.model,
              source: "agent",
              input_tokens: usage.input_tokens,
              output_tokens: usage.output_tokens
            })
          end
        end

        report = build_memory_report(name, Keyword.put(opts, :semantic_query, task))
        {:ok, result <> report}
      end
    )
  end

  defp build_memory_report(agent_name, opts) do
    case opts[:memory] do
      %{user_id: uid, project_id: pid, session_id: sid} = mem ->
        aid = Map.get(mem, :agent_id) || agent_name
        semantic_query = opts[:semantic_query] || ""
        Memory.ContextBuilder.build_report(uid, pid, aid, sid, semantic_query: semantic_query)

      _ ->
        ""
    end
  rescue
    error ->
      Logger.warning("Pipe: build_memory_report failed: #{inspect(error)}")
      ""
  end

  # -- Private: loop execution --

  defp run_loop(ctx, messages, memory_opts) do
    messages = maybe_inject_memory(messages, memory_opts)
    ctx = Map.put(ctx, :input_messages, messages)
    usage = %{input_tokens: 0, output_tokens: 0}

    case think(ctx, messages) do
      {:ok, response} -> do_loop(ctx, [response], 0, add_usage(usage, response))
      {:error, reason} -> {"Error: #{inspect(reason)}", usage}
    end
  end

  defp do_loop(ctx, generated, iteration, usage) do
    last = List.last(generated)

    cond do
      not has_tool_calls?(last) ->
        {last.content || "", usage}

      iteration >= ctx.max_iterations ->
        Logger.warning("Pipe: hit max_iterations (#{ctx.max_iterations})")
        {last.content || "", usage}

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
            do_loop(
              ctx,
              generated ++ [result_message, response],
              iteration + 1,
              add_usage(usage, response)
            )

          {:error, reason} ->
            {"Error: #{inspect(reason)}", usage}
        end
    end
  end

  defp add_usage(acc, %Message{usage: %{input_tokens: i, output_tokens: o}}) do
    %{acc | input_tokens: acc.input_tokens + i, output_tokens: acc.output_tokens + o}
  end

  defp add_usage(acc, _), do: acc

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

  @doc """
  Run a budget-aware orchestrator with specialist pool.

  GenStage-powered replacement for `through/4` with delegate tools.
  The orchestrator plans and dispatches tasks to specialists concurrently,
  re-evaluating after each result.

  ## Options
  - `:budget` — total token budget for this run
  - `:max_concurrency` — max parallel specialists (default: 3)
  - `:specialists` — map of `%{name => %Specialist{}}` configs
  - `:model_fn` — override LLM calls for testing (1-arg for Planner)
  - `:run_id` — custom run ID
  - `:timeout` — max wait time (default: 300_000ms)

  ## Example

      specialists = %{
        "researcher" => %Specialist{name: "researcher", ...},
        "analyst" => %Specialist{name: "analyst", ...}
      }

      {:ok, result, summary} = Pipe.orchestrate(
        "Analyze AAPL stock",
        model_client,
        specialists: specialists,
        budget: 100_000,
        max_concurrency: 3
      )
  """
  def orchestrate(goal, model_client, opts \\ []) do
    specialists = Keyword.get(opts, :specialists, %{})
    budget = Keyword.get(opts, :budget)
    max_concurrency = Keyword.get(opts, :max_concurrency, 3)
    timeout = Keyword.get(opts, :timeout, 300_000)
    model_fn = Keyword.get(opts, :model_fn)
    run_id = Keyword.get(opts, :run_id)

    orch_opts = [
      model_client: model_client,
      specialists: specialists,
      max_concurrency: max_concurrency,
      budget: budget
    ]

    with {:ok, orch} <- Orchestrator.start_link(orch_opts),
         {:ok, pool} <- start_pool(orch, specialists, max_concurrency, model_fn) do
      try do
        run_opts = [timeout: timeout, model_fn: model_fn]
        run_opts = if run_id, do: Keyword.put(run_opts, :run_id, run_id), else: run_opts

        Orchestrator.run(orch, goal, run_opts)
      after
        Supervisor.stop(pool, :normal)
        Orchestrator.stop(orch)
      end
    end
  end

  defp start_pool(orchestrator, specialists, max_demand, model_fn) do
    pool_opts = if model_fn, do: [model_fn: model_fn], else: []

    Specialist.Pool.start_link(
      orchestrator: orchestrator,
      specialists: specialists,
      max_demand: max_demand,
      pool_opts: pool_opts
    )
  end
end
