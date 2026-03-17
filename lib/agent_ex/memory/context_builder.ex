defmodule AgentEx.Memory.ContextBuilder do
  @moduledoc """
  Composes all memory tiers + knowledge graph into an LLM-ready message list.
  All operations are scoped by `agent_id` — each agent gets its own context view.
  """

  alias AgentEx.Memory.{
    KnowledgeGraph,
    PersistentMemory,
    SemanticMemory,
    WorkingMemory
  }

  @default_budgets %{
    persistent: 500,
    knowledge_graph: 1000,
    semantic: 500,
    conversation: 4000,
    total: 8000
  }

  def build(agent_id, session_id, opts \\ []) do
    semantic_query = opts[:semantic_query] || ""
    budgets = Map.merge(@default_budgets, opts[:budgets] || %{})

    tasks = [
      Task.async(fn -> gather_persistent(agent_id) end),
      Task.async(fn -> gather_knowledge_graph(agent_id, semantic_query) end),
      Task.async(fn -> gather_semantic(agent_id, semantic_query) end),
      Task.async(fn -> gather_conversation(agent_id, session_id) end)
    ]

    [persistent, kg, semantic, conversation] = Task.await_many(tasks, 30_000)

    system_parts =
      [
        truncate_section(persistent, budgets.persistent),
        truncate_section(kg, budgets.knowledge_graph),
        truncate_section(semantic, budgets.semantic)
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

  defp gather_persistent(agent_id) do
    case PersistentMemory.Store.to_context_messages(agent_id) do
      [%{content: content} | _] -> content
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp gather_knowledge_graph(_agent_id, ""), do: ""

  defp gather_knowledge_graph(agent_id, query),
    do: gather_tier(KnowledgeGraph.Store, agent_id, query)

  defp gather_semantic(_agent_id, ""), do: ""
  defp gather_semantic(agent_id, query), do: gather_tier(SemanticMemory.Store, agent_id, query)

  defp gather_tier(module, agent_id, query) do
    case module.to_context_messages(agent_id, query) do
      [%{content: content} | _] -> content
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp gather_conversation(agent_id, session_id) do
    WorkingMemory.Server.to_context_messages(agent_id, session_id)
  rescue
    _ -> []
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
