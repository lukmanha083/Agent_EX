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

  alias AgentEx.EventLoop.BroadcastHandler
  alias AgentEx.Memory.Promotion
  alias AgentEx.{Message, ModelClient, Orchestrator, Specialist, Tool, ToolAgent}

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
    {:ok, tool_agent} = ToolAgent.start_link(tools: tools)

    memory_opts = resolve_memory_opts(opts[:memory], agent.name)

    # Start working memory session before ToolCallerLoop (needed for Tier 1 storage)
    maybe_start_session(memory_opts)

    loop_opts =
      [
        max_iterations: agent.max_iterations,
        intervention: agent.intervention || [],
        memory: memory_opts,
        tool_timeout: 180_000,
        # Skip reasoning_first when model_fn is provided (test mode)
        reasoning_first: Keyword.get(opts, :model_fn) == nil
      ]
      |> maybe_put_opt(:model_fn, Keyword.get(opts, :model_fn))
      |> maybe_put_opt(:context_window, memory_opts && memory_opts[:context_window])

    try do
      case AgentEx.ToolCallerLoop.run(tool_agent, model_client, messages, tools, loop_opts) do
        {:ok, generated} ->
          {extract_final_text(generated), extract_usage(generated)}

        {:error, reason} ->
          {"Error: #{inspect(reason)}", %{input_tokens: 0, output_tokens: 0}}
      end
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
      description:
        "Delegate a task to #{name}. #{truncate_description(agent.system_message, 200)}",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{"type" => "string", "description" => "The task to delegate to #{name}"}
        },
        "required" => ["task"]
      },
      function: fn %{"task" => task} ->
        # Add broadcast handler for inner tool calls if run_id is available
        agent_with_broadcast = maybe_add_broadcast(agent, opts[:run_id])

        # Generate session_id per delegation so memory + promotion share it
        session_id = generate_session_id()

        delegate_opts =
          Keyword.update(opts, :memory, nil, fn
            %{} = mem -> Map.put(mem, :session_id, session_id)
            other -> other
          end)

        t_start = System.monotonic_time(:millisecond)
        {result, usage} = through(task, agent_with_broadcast, model_client, delegate_opts)
        duration_ms = System.monotonic_time(:millisecond) - t_start

        if model_client do
          Logger.info(
            "Pipe.delegate_tool: agent=#{name} duration=#{duration_ms}ms " <>
              "usage=#{inspect(usage)} project_id=#{inspect(model_client.project_id)}"
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

        # Promote: session summary → Tier 3, skill extraction → Tier 4 (async)
        # Use agent.name (same key through/4 uses) so promotion queries
        # the correct storage — name param can differ from agent.name
        resolved_memory = resolve_memory_opts(delegate_opts[:memory], agent.name)
        maybe_promote_delegate(resolved_memory, model_client)

        {:ok, result}
      end
    )
  end

  defp maybe_promote_delegate(nil, _model_client), do: :ok

  defp maybe_promote_delegate(%{user_id: uid, project_id: pid, agent_id: aid} = mem, mc) do
    sid = Map.get(mem, :session_id)
    if is_nil(sid), do: throw(:no_session)

    messages = AgentEx.Memory.get_messages(uid, pid, aid, sid)

    if messages != [] do
      Task.Supervisor.start_child(AgentEx.TaskSupervisor, fn ->
        try do
          Promotion.promote_from_messages(uid, pid, aid, sid, messages, mc)
        rescue
          e -> Logger.warning("Pipe: delegate promotion failed: #{Exception.message(e)}")
        end
      end)
    end
  catch
    :no_session -> :ok
  end

  defp maybe_promote_delegate(_, _), do: :ok

  defp maybe_add_broadcast(%Agent{} = agent, nil), do: agent

  defp maybe_add_broadcast(%Agent{} = agent, run_id) do
    handler = BroadcastHandler.new(run_id)
    %{agent | intervention: (agent.intervention || []) ++ [handler]}
  end

  # -- Private helpers --

  defp resolve_memory_opts(nil, _agent_name), do: nil

  defp resolve_memory_opts(%{user_id: uid, project_id: pid} = mem, agent_name) do
    %{
      user_id: uid,
      project_id: pid,
      agent_id: Map.get(mem, :agent_id) || agent_name,
      session_id: Map.get(mem, :session_id, generate_session_id()),
      context_window: Map.get(mem, :context_window)
    }
  end

  defp resolve_memory_opts(_, _), do: nil

  defp truncate_description(nil, _max), do: ""
  defp truncate_description(text, max) when byte_size(text) <= max, do: text

  defp truncate_description(text, max) do
    String.slice(text, 0, max) <> "..."
  end

  defp generate_session_id do
    "delegate-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
  end

  defp maybe_start_session(nil), do: :ok

  defp maybe_start_session(%{user_id: uid, project_id: pid, agent_id: aid, session_id: sid}) do
    case AgentEx.Memory.start_session(uid, pid, aid, sid) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Logger.warning("Pipe: failed to start session: #{inspect(reason)}")
    end
  end

  defp maybe_start_session(_), do: :ok

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp extract_final_text(generated) do
    generated
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %Message{role: :assistant, content: content} when is_binary(content) and content != "" ->
        content

      _ ->
        nil
    end)
  end

  defp extract_usage(generated) do
    Enum.reduce(generated, %{input_tokens: 0, output_tokens: 0}, fn
      %Message{usage: %{input_tokens: i, output_tokens: o}}, acc ->
        %{acc | input_tokens: acc.input_tokens + i, output_tokens: acc.output_tokens + o}

      _, acc ->
        acc
    end)
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

    case Orchestrator.start_link(orch_opts) do
      {:ok, orch} ->
        case start_pool(orch, specialists, max_concurrency, model_fn) do
          {:ok, pool} ->
            try do
              run_opts = [timeout: timeout, model_fn: model_fn]
              run_opts = if run_id, do: Keyword.put(run_opts, :run_id, run_id), else: run_opts
              Orchestrator.run(orch, goal, run_opts)
            after
              Supervisor.stop(pool, :normal)
              Orchestrator.stop(orch)
            end

          error ->
            Orchestrator.stop(orch)
            error
        end

      error ->
        error
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
