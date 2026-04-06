defmodule AgentEx.Memory.SemanticMemory.Store do
  @moduledoc """
  Tier 3: Semantic memory using pgvector embeddings stored in Postgres.
  All operations are scoped by `(project_id, agent_id)` via SQL WHERE clauses.
  """

  @behaviour AgentEx.Memory.Tier

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias AgentEx.Memory.Embeddings
  alias AgentEx.Memory.SemanticMemory.Memory
  alias AgentEx.Repo

  require Logger

  # --- Public API ---

  def store(project_id, agent_id, text, type \\ "general", session_id \\ "") do
    with {:ok, vector} <- Embeddings.embed(text) do
      %Memory{}
      |> Memory.changeset(%{
        project_id: project_id,
        agent_id: agent_id,
        content: text,
        memory_type: type,
        session_id: session_id,
        embedding: vector
      })
      |> Repo.insert()
    end
  end

  def search(project_id, agent_id, query, limit \\ 5) do
    with {:ok, vector} <- Embeddings.embed(query) do
      results =
        from(m in Memory,
          where: m.project_id == ^project_id and m.agent_id == ^agent_id,
          order_by: cosine_distance(m.embedding, ^vector),
          limit: ^limit,
          select: %{
            id: m.id,
            content: m.content,
            memory_type: m.memory_type,
            session_id: m.session_id,
            inserted_at: m.inserted_at
          }
        )
        |> Repo.all()

      {:ok, results}
    end
  end

  def delete(id) do
    case Repo.get(Memory, id) do
      nil -> {:error, :not_found}
      memory -> Repo.delete(memory)
    end
  end

  @doc "Delete all semantic memories for an agent within a project."
  def delete_by_agent(project_id, agent_id) do
    {count, _} =
      from(m in Memory,
        where: m.project_id == ^project_id and m.agent_id == ^agent_id
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc "Delete all semantic memories for a project. (Also handled by CASCADE.)"
  def delete_by_project(project_id) do
    {count, _} =
      from(m in Memory, where: m.project_id == ^project_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages({_user_id, project_id, agent_id}, query) when is_binary(query) do
    case search(project_id, agent_id, query) do
      {:ok, results} when results != [] ->
        content =
          results
          |> Enum.map_join("\n", fn r -> "- #{r.content}" end)

        [%{role: "system", content: "## Relevant Past Context\n#{content}"}]

      _ ->
        []
    end
  end

  @impl AgentEx.Memory.Tier
  def token_estimate({_user_id, project_id, agent_id}, query) when is_binary(query) do
    case search(project_id, agent_id, query) do
      {:ok, results} ->
        Enum.reduce(results, 0, fn r, acc ->
          acc + div(String.length(r.content || ""), 4)
        end)

      _ ->
        0
    end
  end
end
