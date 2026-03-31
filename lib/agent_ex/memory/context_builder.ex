defmodule AgentEx.Memory.ContextBuilder do
  @moduledoc """
  Composes all memory tiers + knowledge graph into an LLM-ready message list.
  All operations are scoped by `(user_id, project_id, agent_id)`.
  """

  alias AgentEx.Memory.{
    KnowledgeGraph,
    PersistentMemory,
    ProceduralMemory,
    SemanticMemory,
    TokenBudget,
    WorkingMemory
  }

  @doc """
  Build context messages from all memory tiers.

  ## Options
  - `:semantic_query` — query string for vector search (default: "")
  - `:budgets` — override calculated budgets (map)
  - `:context_window` — model context window size (used to calculate budgets dynamically)
  """
  def build(user_id, project_id, agent_id, session_id, opts \\ []) do
    semantic_query = opts[:semantic_query] || ""
    context_window = opts[:context_window]

    budgets =
      TokenBudget.calculate(context_window)
      |> Map.merge(opts[:budgets] || %{})

    scope = {user_id, project_id, agent_id}

    tasks = [
      Task.async(fn -> gather_persistent(scope) end),
      Task.async(fn -> gather_knowledge_graph(scope, semantic_query) end),
      Task.async(fn -> gather_semantic(scope, semantic_query) end),
      Task.async(fn -> gather_procedural(scope) end),
      Task.async(fn -> gather_conversation(scope, session_id) end)
    ]

    [persistent, kg, semantic, procedural, conversation] = Task.await_many(tasks, 30_000)

    system_parts =
      [
        truncate_section(persistent, budgets.persistent),
        truncate_section(kg, budgets.knowledge_graph),
        truncate_section(semantic, budgets.semantic),
        truncate_section(procedural, budgets.procedural)
      ]
      |> Enum.reject(&(&1 == ""))

    system_message =
      if system_parts != [] do
        [%{role: "system", content: Enum.join(system_parts, "\n\n")}]
      else
        []
      end

    conversation_messages = truncate_conversation(conversation, budgets.conversation)
    system_message ++ conversation_messages
  end

  @doc """
  Build a compact memory report for the orchestrator.

  Unlike `build/5` which injects full context into the LLM prompt,
  this returns a structured text summary of what an agent knows —
  key facts, relevant skills, and related entities. The orchestrator
  sees this as part of the delegate tool result.

  Returns `""` if the agent has no accumulated memory.
  """
  def build_report(user_id, project_id, agent_id, session_id, opts \\ []) do
    semantic_query = opts[:semantic_query] || ""
    scope = {user_id, project_id, agent_id}

    tasks = [
      Task.async(fn -> gather_persistent(scope) end),
      Task.async(fn -> gather_knowledge_graph(scope, semantic_query) end),
      Task.async(fn -> gather_procedural(scope) end),
      Task.async(fn -> summarize_session(scope, session_id) end)
    ]

    [persistent, kg, procedural, session_summary] = Task.await_many(tasks, 15_000)

    sections =
      [
        format_report_section("Key Facts", persistent, 300),
        format_report_section("Known Entities", kg, 400),
        format_report_section("Learned Skills", procedural, 300),
        format_report_section("Session Activity", session_summary, 200)
      ]
      |> Enum.reject(&is_nil/1)

    case sections do
      [] -> ""
      parts -> "\n\n---\n## Agent Memory Report\n" <> Enum.join(parts, "\n")
    end
  end

  defp format_report_section(_title, "", _budget), do: nil
  defp format_report_section(_title, nil, _budget), do: nil

  defp format_report_section(title, content, budget) do
    truncated = truncate_section(content, budget)
    if truncated == "", do: nil, else: "### #{title}\n#{truncated}"
  end

  defp summarize_session(scope, session_id) do
    messages = gather_conversation(scope, session_id)

    case messages do
      [] ->
        ""

      msgs ->
        count = length(msgs)
        roles = Enum.frequencies_by(msgs, & &1[:role])
        user_count = Map.get(roles, "user", 0)
        assistant_count = Map.get(roles, "assistant", 0)
        "#{count} messages in session (#{user_count} user, #{assistant_count} assistant)"
    end
  end

  defp gather_persistent(scope) do
    case PersistentMemory.Store.to_context_messages(scope) do
      [%{content: content} | _] -> content
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp gather_procedural(scope) do
    case ProceduralMemory.Store.to_context_messages(scope) do
      [%{content: content} | _] -> content
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp gather_knowledge_graph(_scope, ""), do: ""
  defp gather_knowledge_graph(scope, query), do: gather_tier(KnowledgeGraph.Store, scope, query)

  defp gather_semantic(_scope, ""), do: ""
  defp gather_semantic(scope, query), do: gather_tier(SemanticMemory.Store, scope, query)

  defp gather_tier(module, scope, query) do
    case module.to_context_messages(scope, query) do
      [%{content: content} | _] -> content
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp gather_conversation(scope, session_id) do
    WorkingMemory.Server.to_context_messages(scope, session_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp truncate_section(text, budget_tokens) when is_binary(text) do
    estimated_tokens = div(String.length(text), 4)

    if estimated_tokens <= budget_tokens do
      text
    else
      max_chars = budget_tokens * 4
      String.slice(text, 0, max_chars) <> "\n... (truncated)"
    end
  end

  defp truncate_section(_, _), do: ""

  defp truncate_conversation(messages, budget_tokens) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, tokens} ->
      msg_tokens = div(String.length(msg[:content] || ""), 4)

      if tokens + msg_tokens <= budget_tokens do
        {:cont, {[msg | acc], tokens + msg_tokens}}
      else
        {:halt, {acc, tokens}}
      end
    end)
    |> elem(0)
  end

  defp truncate_conversation(_, _), do: []
end
