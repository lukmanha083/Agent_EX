defmodule AgentEx.Memory.KnowledgeGraph.Retriever do
  @moduledoc """
  Hybrid graph+vector retrieval. Executes three strategies in parallel:
  1. Vector search for semantically similar episodes (filtered by agent_id)
  2. Entity graph traversal (shared across agents)
  3. Fact search (shared across agents)
  """

  alias AgentEx.Memory.Embeddings
  alias AgentEx.Memory.SemanticMemory.Client

  require Logger

  def hybrid_search(_user_id, _project_id, agent_id, query, limit \\ 5) do
    with {:ok, vector} <- Embeddings.embed(query) do
      tasks = [
        Task.async(fn -> search_episodes(agent_id, vector, limit) end),
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

  # --- Strategy 1: Episode vector search (agent-scoped) ---

  defp search_episodes(agent_id, vector, limit) do
    # Over-fetch then filter by agent_id
    fetch_limit = limit * 3

    case Client.query("SearchEpisodes", %{query_vector: vector, limit: fetch_limit}) do
      {:ok, response} ->
        episodes =
          response
          |> extract_episodes()
          |> Enum.filter(fn ep ->
            ep_agent = ep[:agent_id]
            is_nil(ep_agent) or ep_agent == agent_id
          end)
          |> Enum.take(limit)

        {:ok, episodes}

      error ->
        error
    end
  end

  defp extract_episodes(response) do
    extract_items(response, fn item ->
      %{
        type: :episode,
        content: prop(item, "content_summary", ""),
        agent_id: item["agent_id"] || get_in(item, ["properties", "agent_id"]),
        score: item["score"] || 0.0
      }
    end)
  end

  # --- Strategy 2: Entity graph traversal (shared) ---

  defp search_entities(vector, limit) do
    search_and_extract("HybridEntitySearch", vector, limit, &extract_entities/1)
  end

  defp extract_entities(%{"entities" => entities, "related" => related})
       when is_list(entities) do
    entity_items =
      Enum.map(entities, fn e ->
        %{
          type: :entity,
          name: prop(e, "name", ""),
          entity_type: prop(e, "entity_type", ""),
          description: prop(e, "description", "")
        }
      end)

    fact_items =
      Enum.map(related || [], fn f ->
        %{
          type: :fact,
          description: prop(f, "description", ""),
          fact_type: prop(f, "fact_type", ""),
          confidence: prop(f, "confidence", "MEDIUM")
        }
      end)

    entity_items ++ fact_items
  end

  defp extract_entities(_), do: []

  # --- Strategy 3: Fact vector search (shared) ---

  defp search_facts(vector, limit) do
    search_and_extract("SearchFacts", vector, limit, &extract_facts/1)
  end

  defp search_and_extract(query_name, vector, limit, extractor) do
    case Client.query(query_name, %{query_vector: vector, limit: limit}) do
      {:ok, response} -> {:ok, extractor.(response)}
      error -> error
    end
  end

  defp extract_facts(response) do
    extract_items(response, fn item ->
      %{
        type: :fact_search,
        description: prop(item, "fact_description", ""),
        source: prop(item, "source_entity", ""),
        target: prop(item, "target_entity", ""),
        score: item["score"] || 0.0
      }
    end)
  end

  # Extracts items from HelixDB responses that use either "embeddings" or "results" keys
  defp extract_items(%{"embeddings" => items}, mapper) when is_list(items),
    do: Enum.map(items, mapper)

  defp extract_items(%{"results" => items}, mapper) when is_list(items),
    do: Enum.map(items, mapper)

  defp extract_items(_, _), do: []

  # Gets a property from either top-level or nested "properties" map
  defp prop(item, key, default) do
    item[key] || get_in(item, ["properties", key]) || default
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
