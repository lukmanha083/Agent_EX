defmodule AgentEx.Memory do
  @moduledoc """
  Public API facade for the 3-tier agent memory system with knowledge graph.

  All operations are scoped by `(user_id, project_id, agent_id)` for multi-tenant isolation.

  ## Tiers
  - **Tier 1 (Working Memory)**: Per-session conversation history
  - **Tier 2 (Persistent Memory)**: Key-value facts (ETS + DETS)
  - **Tier 3 (Semantic Memory)**: Vector-based semantic search (HelixDB)
  - **Knowledge Graph**: Shared entities/facts, per-agent episodes (HelixDB)

  ## Example — multi-agent memory isolation

      uid = 1
      pid = 1

      AgentEx.Memory.start_session(uid, pid, "analyst", "session-1")
      AgentEx.Memory.remember(uid, pid, "analyst", "expertise", "data analysis", "fact")

      AgentEx.Memory.start_session(uid, pid, "writer", "session-1")
      AgentEx.Memory.remember(uid, pid, "writer", "style", "concise", "preference")

      # Each agent's context only sees its own memories
      AgentEx.Memory.build_context(uid, pid, "analyst", "session-1")
      AgentEx.Memory.build_context(uid, pid, "writer", "session-1")
  """

  alias AgentEx.Memory.{
    ContextBuilder,
    KnowledgeGraph,
    PersistentMemory,
    ProceduralMemory,
    Promotion,
    SemanticMemory,
    WorkingMemory
  }

  require Logger

  # --- Session Management (Tier 1) ---

  def start_session(user_id, project_id, agent_id, session_id, opts \\ []) do
    WorkingMemory.Supervisor.start_session(user_id, project_id, agent_id, session_id, opts)
  end

  def stop_session(user_id, project_id, agent_id, session_id) do
    WorkingMemory.Supervisor.stop_session(user_id, project_id, agent_id, session_id)
  end

  def add_message(user_id, project_id, agent_id, session_id, role, content) do
    WorkingMemory.Server.add_message(user_id, project_id, agent_id, session_id, role, content)
  end

  def get_messages(user_id, project_id, agent_id, session_id) do
    WorkingMemory.Server.get_messages(user_id, project_id, agent_id, session_id)
  end

  def get_recent_messages(user_id, project_id, agent_id, session_id, n) do
    WorkingMemory.Server.get_recent(user_id, project_id, agent_id, session_id, n)
  end

  # --- Persistent Memory (Tier 2) ---

  def remember(user_id, project_id, agent_id, key, value, type \\ "preference") do
    PersistentMemory.Store.put(user_id, project_id, agent_id, key, value, type)
  end

  def recall(user_id, project_id, agent_id, key) do
    PersistentMemory.Store.get(user_id, project_id, agent_id, key)
  end

  def recall_by_type(user_id, project_id, agent_id, type) do
    PersistentMemory.Store.get_by_type(user_id, project_id, agent_id, type)
  end

  def forget(user_id, project_id, agent_id, key) do
    PersistentMemory.Store.delete(user_id, project_id, agent_id, key)
  end

  # --- Semantic Memory (Tier 3) ---

  def store_memory(user_id, project_id, agent_id, text, type \\ "general", session_id \\ "") do
    SemanticMemory.Store.store(user_id, project_id, agent_id, text, type, session_id)
  end

  def search_memory(user_id, project_id, agent_id, query, limit \\ 5) do
    SemanticMemory.Store.search(user_id, project_id, agent_id, query, limit)
  end

  # --- Knowledge Graph ---

  def ingest(user_id, project_id, agent_id, text, role \\ "user") do
    KnowledgeGraph.Store.ingest(user_id, project_id, agent_id, text, role)
  end

  @doc "Query an entity by name (shared across agents)."
  def query_entity(name) do
    KnowledgeGraph.Store.query_entity(name)
  end

  @doc "Query related entities (shared across agents)."
  def query_related(name, hops \\ 1) do
    KnowledgeGraph.Store.query_related(name, hops)
  end

  def hybrid_search(user_id, project_id, agent_id, query, limit \\ 5) do
    KnowledgeGraph.Store.hybrid_search(user_id, project_id, agent_id, query, limit)
  end

  # --- Procedural Memory (Tier 4: Skills) ---

  @doc "Store or update a skill."
  def store_skill(user_id, project_id, agent_id, %ProceduralMemory.Skill{} = skill) do
    ProceduralMemory.Store.put(user_id, project_id, agent_id, skill)
  end

  @doc "Retrieve a specific skill by name."
  def get_skill(user_id, project_id, agent_id, skill_name) do
    ProceduralMemory.Store.get(user_id, project_id, agent_id, skill_name)
  end

  @doc "Get all skills for an agent."
  def list_skills(user_id, project_id, agent_id) do
    ProceduralMemory.Store.all(user_id, project_id, agent_id)
  end

  @doc "Get top skills by confidence score."
  def top_skills(user_id, project_id, agent_id, limit \\ 10) do
    ProceduralMemory.Store.get_top_skills(user_id, project_id, agent_id, limit)
  end

  @doc "Get skills in a specific domain."
  def skills_by_domain(user_id, project_id, agent_id, domain) do
    ProceduralMemory.Store.get_by_domain(user_id, project_id, agent_id, domain)
  end

  @doc "Delete a specific skill."
  def delete_skill(user_id, project_id, agent_id, skill_name) do
    ProceduralMemory.Store.delete(user_id, project_id, agent_id, skill_name)
  end

  # --- Memory Promotion ---

  @doc "Close a session and promote a summary to Tier 3."
  def close_session_with_summary(
        user_id,
        project_id,
        agent_id,
        session_id,
        model_client,
        opts \\ []
      ) do
    Promotion.close_session_with_summary(
      user_id,
      project_id,
      agent_id,
      session_id,
      model_client,
      opts
    )
  end

  @doc "Build a save_memory tool for an agent."
  def save_memory_tool(opts) do
    Promotion.save_memory_tool(opts)
  end

  # --- Data Cleanup ---

  @doc """
  Delete all memory data for an agent across all tiers.

  - Tier 2: Removes all persistent memory entries (ETS + DETS)
  - Tier 3: Removes semantic memory vectors from HelixDB (best-effort)
  - Tier 4: Removes procedural skills (ETS + DETS)
  - KG: Removes episode embeddings from HelixDB (best-effort; shared entities/facts kept)
  """
  def delete_agent_data(user_id, project_id, agent_id) do
    tasks = [
      Task.async(fn ->
        {:persistent, PersistentMemory.Store.delete_all(user_id, project_id, agent_id)}
      end),
      Task.async(fn ->
        {:semantic, SemanticMemory.Store.delete_by_agent(user_id, project_id, agent_id)}
      end),
      Task.async(fn ->
        {:knowledge_graph, KnowledgeGraph.Store.delete_by_agent(user_id, project_id, agent_id)}
      end),
      Task.async(fn ->
        {:procedural, ProceduralMemory.Store.delete_all(user_id, project_id, agent_id)}
      end)
    ]

    results = collect_task_results(tasks)
    {:ok, results}
  end

  @doc """
  Delete all memory data for a project across all tiers.

  - Tier 2: Direct project-scoped delete from ETS/DETS
  - Tier 3: Removes semantic memory vectors matching project_id (best-effort)
  - Tier 4: Removes procedural skills matching project_id (ETS + DETS)
  - KG: Removes episode embeddings matching project_id (best-effort; shared entities/facts kept)
  """
  def delete_project_data(user_id, project_id) do
    tasks = [
      Task.async(fn ->
        {:persistent, PersistentMemory.Store.delete_by_project(user_id, project_id)}
      end),
      Task.async(fn ->
        {:semantic, SemanticMemory.Store.delete_by_project(user_id, project_id)}
      end),
      Task.async(fn ->
        {:knowledge_graph, KnowledgeGraph.Store.delete_by_project(user_id, project_id)}
      end),
      Task.async(fn ->
        {:procedural, ProceduralMemory.Store.delete_by_project(user_id, project_id)}
      end)
    ]

    results = collect_task_results(tasks)
    {:ok, results}
  end

  defp collect_task_results(tasks) do
    tasks
    |> Task.yield_many(60_000)
    |> Enum.map(fn {task, result} ->
      case result do
        {:ok, value} ->
          value

        nil ->
          Task.shutdown(task, :brutal_kill)
          Logger.warning("Memory cleanup task timed out: #{inspect(task.ref)}")
          {:error, :timeout}

        {:exit, reason} ->
          Logger.warning("Memory cleanup task crashed: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  # --- Context Building ---

  def build_context(user_id, project_id, agent_id, session_id, opts \\ []) do
    ContextBuilder.build(user_id, project_id, agent_id, session_id, opts)
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
  Injects memory context into a message list.

  Inserts system-level context (Tier 2/3/KG) after existing system messages,
  then conversation history (Tier 1) before the current user messages.
  """
  def inject_memory_context(messages, user_id, project_id, agent_id, session_id) do
    alias AgentEx.Message

    semantic_query = last_user_content(messages)

    context_messages =
      build_context(user_id, project_id, agent_id, session_id, semantic_query: semantic_query)

    {system_ctx, conversation_ctx} =
      Enum.split_with(context_messages, &(&1.role == "system"))

    memory_system_msgs = Enum.map(system_ctx, &Message.system(&1.content))

    memory_conversation_msgs =
      Enum.map(conversation_ctx, fn msg ->
        role = if is_atom(msg.role), do: Atom.to_string(msg.role), else: msg.role

        case role do
          "user" -> Message.user(msg.content)
          "assistant" -> Message.assistant(msg.content)
          other -> %Message{role: String.to_existing_atom(other), content: msg.content}
        end
      end)

    {system_msgs, rest} = Enum.split_while(messages, &(&1.role == :system))
    system_msgs ++ memory_system_msgs ++ memory_conversation_msgs ++ rest
  end
end
