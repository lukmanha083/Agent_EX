defmodule AgentEx.Memory.KnowledgeGraph.Retriever do
  @moduledoc """
  Hybrid graph+vector retrieval using Postgres + pgvector.
  Executes three strategies in parallel:
  1. Vector search for semantically similar episodes (filtered by project/agent)
  2. Entity graph traversal (shared across agents)
  3. Fact search (shared across agents)
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias AgentEx.Memory.Embeddings
  alias AgentEx.Memory.KnowledgeGraph.{Entity, Episode, Fact}
  alias AgentEx.Repo

  require Logger

  def hybrid_search(project_id, agent_id, query, limit \\ 5) do
    with {:ok, vector} <- Embeddings.embed(query) do
      tasks = [
        Task.async(fn -> search_episodes(project_id, agent_id, vector, limit) end),
        Task.async(fn -> search_entities(vector, limit) end),
        Task.async(fn -> search_facts(vector, limit) end)
      ]

      results = Task.await_many(tasks, 15_000)

      [episodes, entities, facts] =
        Enum.map(results, fn
          {:ok, data} -> data
          _ -> []
        end)

      context = format_context(entities, facts, episodes)
      {:ok, context}
    end
  end

  # --- Strategy 1: Episode vector search (project+agent scoped) ---

  defp search_episodes(project_id, agent_id, vector, limit) do
    episodes =
      from(e in Episode,
        where:
          e.project_id == ^project_id and
            e.agent_id == ^agent_id and
            not is_nil(e.content_embedding),
        order_by: cosine_distance(e.content_embedding, ^vector),
        limit: ^limit,
        select: %{content: e.content}
      )
      |> Repo.all()
      |> Enum.map(&Map.put(&1, :type, :episode))

    {:ok, episodes}
  end

  # --- Strategy 2: Entity graph traversal (shared) ---

  defp search_entities(vector, limit) do
    entities =
      from(e in Entity,
        where: not is_nil(e.name_embedding),
        order_by: cosine_distance(e.name_embedding, ^vector),
        limit: ^limit,
        select: %{
          id: e.id,
          name: e.name,
          entity_type: e.entity_type,
          description: e.description
        }
      )
      |> Repo.all()

    # For top entities, fetch their related facts
    entity_ids = Enum.map(entities, & &1.id)

    related_facts =
      if entity_ids != [] do
        from(f in Fact,
          where: f.source_entity_id in ^entity_ids or f.target_entity_id in ^entity_ids,
          select: %{
            description: f.description,
            fact_type: f.fact_type,
            confidence: f.confidence
          }
        )
        |> Repo.all()
      else
        []
      end

    entity_items = Enum.map(entities, fn e -> Map.put(e, :type, :entity) end)
    fact_items = Enum.map(related_facts, fn f -> Map.put(f, :type, :fact) end)

    {:ok, entity_items ++ fact_items}
  end

  # --- Strategy 3: Fact vector search (shared) ---

  defp search_facts(vector, limit) do
    facts =
      from(f in Fact,
        where: not is_nil(f.description_embedding),
        order_by: cosine_distance(f.description_embedding, ^vector),
        limit: ^limit,
        join: src in Entity,
        on: src.id == f.source_entity_id,
        join: tgt in Entity,
        on: tgt.id == f.target_entity_id,
        select: %{
          description: f.description,
          source: src.name,
          target: tgt.name
        }
      )
      |> Repo.all()
      |> Enum.map(&Map.put(&1, :type, :fact_search))

    {:ok, facts}
  end

  # --- Formatting ---

  defp format_context(entities, facts, episodes) do
    fact_lines =
      (extract_fact_lines(entities) ++ extract_fact_search_lines(facts))
      |> Enum.uniq()

    episode_lines =
      episodes
      |> Enum.reject(&(&1.content == ""))
      |> Enum.map(& &1.content)
      |> Enum.uniq()

    [
      format_section("Known facts", fact_lines),
      format_section("Related context", episode_lines)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp format_section(_header, []), do: ""
  defp format_section(header, lines), do: "#{header}:\n" <> Enum.map_join(lines, "\n", &"- #{&1}")

  defp extract_fact_lines(entities) do
    entities
    |> Enum.filter(&(&1.type == :fact))
    |> Enum.map(fn f ->
      confidence = if f[:confidence], do: " (#{f.confidence} confidence)", else: ""
      "#{f.description}#{confidence}"
    end)
  end

  defp extract_fact_search_lines(facts) do
    facts
    |> Enum.reject(&(&1.description == ""))
    |> Enum.map(fn f -> "#{f.source} → #{f.target}: #{f.description}" end)
  end
end
