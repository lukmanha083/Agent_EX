defmodule AgentEx.Memory do
  @moduledoc """
  Public API facade for the 3-tier agent memory system with knowledge graph.

  All operations are scoped by `agent_id` — each agent (GenServer, Swarm participant,
  or standalone) gets its own isolated memory space.

  ## Tiers
  - **Tier 1 (Working Memory)**: Per-agent, per-session conversation history
  - **Tier 2 (Persistent Memory)**: Per-agent key-value facts (ETS + DETS)
  - **Tier 3 (Semantic Memory)**: Per-agent vector-based semantic search (HelixDB)
  - **Knowledge Graph**: Shared entities/facts, per-agent episodes (HelixDB)

  ## Example — multi-agent memory isolation

      # Analyst agent remembers its own preferences
      AgentEx.Memory.start_session("analyst", "session-1")
      AgentEx.Memory.remember("analyst", "expertise", "data analysis", "fact")
      AgentEx.Memory.add_message("analyst", "session-1", "user", "Analyze AAPL")

      # Writer agent has its own memory space
      AgentEx.Memory.start_session("writer", "session-1")
      AgentEx.Memory.remember("writer", "style", "concise", "preference")

      # Each agent's context only sees its own memories
      AgentEx.Memory.build_context("analyst", "session-1")  # analyst's view
      AgentEx.Memory.build_context("writer", "session-1")   # writer's view
  """

  alias AgentEx.Memory.{
    ContextBuilder,
    KnowledgeGraph,
    PersistentMemory,
    SemanticMemory,
    WorkingMemory
  }

  # --- Session Management (Tier 1) ---

  def start_session(agent_id, session_id, opts \\ []) do
    WorkingMemory.Supervisor.start_session(agent_id, session_id, opts)
  end

  def stop_session(agent_id, session_id) do
    WorkingMemory.Supervisor.stop_session(agent_id, session_id)
  end

  def add_message(agent_id, session_id, role, content) do
    WorkingMemory.Server.add_message(agent_id, session_id, role, content)
  end

  def get_messages(agent_id, session_id) do
    WorkingMemory.Server.get_messages(agent_id, session_id)
  end

  def get_recent_messages(agent_id, session_id, n) do
    WorkingMemory.Server.get_recent(agent_id, session_id, n)
  end

  # --- Persistent Memory (Tier 2) ---

  def remember(agent_id, key, value, type \\ "preference") do
    PersistentMemory.Store.put(agent_id, key, value, type)
  end

  def recall(agent_id, key) do
    PersistentMemory.Store.get(agent_id, key)
  end

  def recall_by_type(agent_id, type) do
    PersistentMemory.Store.get_by_type(agent_id, type)
  end

  def forget(agent_id, key) do
    PersistentMemory.Store.delete(agent_id, key)
  end

  # --- Semantic Memory (Tier 3) ---

  def store_memory(agent_id, text, type \\ "general", session_id \\ "") do
    SemanticMemory.Store.store(agent_id, text, type, session_id)
  end

  def search_memory(agent_id, query, limit \\ 5) do
    SemanticMemory.Store.search(agent_id, query, limit)
  end

  # --- Knowledge Graph ---

  def ingest(agent_id, text, role \\ "user") do
    KnowledgeGraph.Store.ingest(agent_id, text, role)
  end

  @doc "Query an entity by name (shared across agents)."
  def query_entity(name) do
    KnowledgeGraph.Store.query_entity(name)
  end

  @doc "Query related entities (shared across agents)."
  def query_related(name, hops \\ 1) do
    KnowledgeGraph.Store.query_related(name, hops)
  end

  def hybrid_search(agent_id, query, limit \\ 5) do
    KnowledgeGraph.Store.hybrid_search(agent_id, query, limit)
  end

  # --- Context Building ---

  def build_context(agent_id, session_id, opts \\ []) do
    ContextBuilder.build(agent_id, session_id, opts)
  end

  @doc """
  Extracts the last user message content from a list of messages.
  Used as a semantic query hint for memory context injection.
  """
  def last_user_content(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> case do
      %{content: content} when is_binary(content) -> content
      _ -> ""
    end
  end

  @doc """
  Injects memory context system messages into a message list.
  System messages from memory are inserted after existing system messages.
  """
  def inject_memory_context(messages, agent_id, session_id) do
    alias AgentEx.Message

    semantic_query = last_user_content(messages)
    context_messages = build_context(agent_id, session_id, semantic_query: semantic_query)

    memory_system_msgs =
      context_messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(&Message.system(&1.content))

    {system_msgs, rest} = Enum.split_while(messages, &(&1.role == :system))
    system_msgs ++ memory_system_msgs ++ rest
  end
end
