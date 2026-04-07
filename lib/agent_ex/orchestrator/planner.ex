defmodule AgentEx.Orchestrator.Planner do
  @moduledoc """
  LLM-based task scheduling for the orchestrator.

  The Planner is the brain of the orchestration engine — it calls the LLM
  to decompose goals into tasks, re-evaluate after each result, and decide
  when to converge. All planning calls return structured actions that the
  Orchestrator applies to its TaskQueue.
  """

  alias AgentEx.{Message, ModelClient}
  alias AgentEx.Orchestrator.TaskQueue

  require Logger

  @type action ::
          {:add, [map()]}
          | {:drop, [String.t()]}
          | {:reorder, [{String.t(), atom()}]}
          | :converge
          | {:refine, String.t()}

  @doc """
  Initial planning call: decompose a goal into tasks for available specialists.

  Returns `{:ok, [task]}` where each task has `:id`, `:specialist`, `:input`,
  `:priority`, and optionally `:depends_on`.
  """
  def initial_plan(goal, specialists, model_client, opts \\ []) do
    budget_prompt = Keyword.get(opts, :budget_prompt, "")

    specialist_list =
      specialists
      |> Enum.map_join("\n", fn s ->
        "- #{s.name}: #{s.description || s.role || "general specialist"}"
      end)

    system = """
    You are a task planner. Decompose the user's goal into discrete tasks that
    can be assigned to available specialists. Tasks can run in parallel if independent,
    or have dependencies if one requires another's output.

    ## Available Specialists
    #{specialist_list}

    #{budget_prompt}

    ## Output Format
    Respond with ONLY valid JSON — an array of task objects:
    [
      {
        "id": "t1",
        "specialist": "specialist_name",
        "input": "what to do",
        "priority": "high",
        "depends_on": []
      }
    ]

    Priority values: "high", "normal", "low".
    depends_on: array of task IDs that must complete before this task starts.
    Keep task count reasonable (2-8 tasks). Prefer parallel tasks when possible.
    """

    messages = [Message.system(system), Message.user(goal)]

    case call_llm(model_client, messages, opts) do
      {:ok, content} -> parse_tasks(content)
      {:error, _} = err -> err
    end
  end

  @doc """
  Re-evaluate after a specialist reports a result.

  The Planner sees the goal, completed results, pending queue, and budget,
  then decides what to do next: add tasks, drop tasks, reorder, or converge.
  """
  def plan(state, model_client, opts \\ []) do
    completed_text =
      Enum.map_join(state.completed, "\n", fn {id, result} ->
        "- #{id}: #{truncate(result, 200)}"
      end)

    pending_text =
      state.queue
      |> TaskQueue.task_ids()
      |> Enum.join(", ")

    budget_prompt = Keyword.get(opts, :budget_prompt, "")

    system = """
    You are a task planner re-evaluating progress on a goal.

    ## Goal
    #{state.goal}

    ## Completed Tasks
    #{completed_text}

    ## Pending Tasks
    #{pending_text}

    #{budget_prompt}

    ## Instructions
    Decide your next action. Respond with ONLY valid JSON:

    To add tasks: {"action": "add", "tasks": [{"id": "t5", "specialist": "...", "input": "...", "priority": "normal", "depends_on": []}]}
    To drop tasks: {"action": "drop", "task_ids": ["t3"]}
    To reorder: {"action": "reorder", "changes": [{"id": "t3", "priority": "high"}]}
    To finish: {"action": "converge"}
    To request more budget: {"action": "refine", "summary": "progress so far..."}

    Choose ONE action. Prefer "converge" when you have enough results to answer the goal.
    """

    messages = [Message.system(system), Message.user("What should we do next?")]

    case call_llm(model_client, messages, opts) do
      {:ok, content} -> parse_action(content)
      {:error, _} = err -> err
    end
  end

  @doc """
  Final synthesis: merge all completed results into a coherent answer.
  """
  def converge(completed, goal, model_client, opts \\ []) do
    results_text =
      Enum.map_join(completed, "\n\n", fn {id, result} -> "## #{id}\n#{result}" end)

    system = """
    You are synthesizing results from multiple specialist agents into a final,
    coherent response. Combine the information, resolve any contradictions,
    and produce a comprehensive answer to the original goal.
    """

    user = """
    ## Original Goal
    #{goal}

    ## Specialist Results
    #{results_text}

    Synthesize these results into a complete, well-structured response.
    """

    messages = [Message.system(system), Message.user(user)]

    case call_llm(model_client, messages, opts) do
      {:ok, content} -> {:ok, content}
      {:error, _} = err -> err
    end
  end

  # --- Private ---

  defp call_llm(model_client, messages, opts) do
    model_fn = Keyword.get(opts, :model_fn)

    if model_fn do
      model_fn.(messages)
    else
      case ModelClient.create(model_client, messages,
             temperature: 0.0,
             response_format: %{"type" => "json_object"}
           ) do
        {:ok, %Message{content: content}} -> {:ok, content}
        {:error, _} = err -> err
      end
    end
  end

  defp parse_tasks(json_string) do
    case Jason.decode(json_string) do
      {:ok, tasks} when is_list(tasks) ->
        parsed =
          Enum.map(tasks, fn t ->
            %{
              id: t["id"] || generate_id(),
              specialist: t["specialist"],
              input: t["input"],
              priority: parse_priority(t["priority"]),
              depends_on: t["depends_on"] || []
            }
          end)

        {:ok, parsed}

      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        parse_tasks(Jason.encode!(tasks))

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        Logger.error("Planner: failed to parse tasks JSON: #{inspect(reason)}")
        {:error, :parse_error}
    end
  end

  defp parse_action(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} ->
        decode_action(decoded)

      {:error, reason} ->
        Logger.error("Planner: failed to parse action JSON: #{inspect(reason)}")
        {:error, :parse_error}
    end
  end

  defp decode_action(%{"action" => "add", "tasks" => tasks}) do
    case parse_tasks(Jason.encode!(tasks)) do
      {:ok, parsed} -> {:ok, [{:add, parsed}]}
      err -> err
    end
  end

  defp decode_action(%{"action" => "drop", "task_ids" => ids}), do: {:ok, [{:drop, ids}]}

  defp decode_action(%{"action" => "reorder", "changes" => changes}) do
    reorders = Enum.map(changes, fn c -> {c["id"], parse_priority(c["priority"])} end)
    {:ok, [{:reorder, reorders}]}
  end

  defp decode_action(%{"action" => "converge"}), do: {:ok, [:converge]}

  defp decode_action(%{"action" => "refine", "summary" => summary}),
    do: {:ok, [{:refine, summary}]}

  defp decode_action(_), do: {:ok, [:converge]}

  defp parse_priority("high"), do: :high
  defp parse_priority("low"), do: :low
  defp parse_priority(_), do: :normal

  defp truncate(text, max) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end

  defp generate_id, do: "t-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
end
