defmodule AgentEx.Memory.KnowledgeGraph.Store do
  @moduledoc """
  Orchestrates knowledge graph operations, scoped by `(user_id, project_id, agent_id)`.

  - **Episodes** are per-agent (each agent's conversation turns are separate)
  - **Entities** are shared (world knowledge is universal across agents)
  - **Facts** are shared (relationships between entities are universal)
  - **Retrieval** can filter episodes by agent_id while facts are shared
  """

  use GenServer

  @behaviour AgentEx.Memory.Tier

  alias AgentEx.Memory.Embeddings
  alias AgentEx.Memory.KnowledgeGraph.{Extractor, Retriever}
  alias AgentEx.Memory.SemanticMemory.Client

  require Logger

  @entity_similarity_threshold 0.85

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ingest(user_id, project_id, agent_id, text, role \\ "user") do
    GenServer.call(__MODULE__, {:ingest, user_id, project_id, agent_id, text, role}, 60_000)
  end

  def query_entity(name) do
    GenServer.call(__MODULE__, {:query_entity, name}, 30_000)
  end

  def query_related(name, hops \\ 1) do
    GenServer.call(__MODULE__, {:query_related, name, hops}, 30_000)
  end

  def hybrid_search(user_id, project_id, agent_id, query, limit \\ 5) do
    GenServer.call(
      __MODULE__,
      {:hybrid_search, user_id, project_id, agent_id, query, limit},
      30_000
    )
  end

  @doc """
  Delete all episodes and episode embeddings for an agent.

  Entities and facts are shared across agents and are NOT deleted.
  Uses broad vector search + client-side agent_id filter since HelixDB
  doesn't support property-based queries.
  """
  def delete_by_agent(user_id, project_id, agent_id) do
    GenServer.call(__MODULE__, {:delete_by_agent, user_id, project_id, agent_id}, 60_000)
  end

  @doc "Delete all episodes and episode embeddings for a project (scoped by project_id metadata)."
  def delete_by_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:delete_by_project, user_id, project_id}, 60_000)
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages({user_id, project_id, agent_id}, query) when is_binary(query) do
    case hybrid_search(user_id, project_id, agent_id, query) do
      {:ok, context} when context != "" ->
        [%{role: "system", content: "## Knowledge Graph\n#{context}"}]

      _ ->
        []
    end
  end

  @impl AgentEx.Memory.Tier
  def token_estimate({user_id, project_id, agent_id}, query) when is_binary(query) do
    case hybrid_search(user_id, project_id, agent_id, query) do
      {:ok, context} -> div(String.length(context), 4)
      _ -> 0
    end
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:ingest, user_id, project_id, agent_id, text, role}, _from, state) do
    result = run_ingestion_pipeline(user_id, project_id, agent_id, text, role)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:query_entity, name}, _from, state) do
    result = do_query_entity(name)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:query_related, name, hops}, _from, state) do
    result = do_query_related(name, hops)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:hybrid_search, user_id, project_id, agent_id, query, limit}, _from, state) do
    result = Retriever.hybrid_search(user_id, project_id, agent_id, query, limit)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:delete_by_agent, _user_id, _project_id, agent_id}, _from, state) do
    result = do_delete_by_field("agent_id", agent_id)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:delete_by_project, _user_id, project_id}, _from, state) do
    result = do_delete_by_field("project_id", to_string(project_id))
    {:reply, result, state}
  end

  # --- Ingestion Pipeline ---

  defp run_ingestion_pipeline(user_id, project_id, agent_id, text, role) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    with {:ok, episode_id} <- create_episode(agent_id, user_id, project_id, text, role, now),
         :ok <- store_episode_embedding(agent_id, user_id, project_id, episode_id, text),
         {:ok, extraction} <- Extractor.extract(text),
         {:ok, entity_map} <- resolve_entities(extraction.entities, now),
         :ok <- store_facts(extraction.relationships, entity_map, now),
         :ok <- link_entities_to_episode(entity_map, episode_id, extraction) do
      {:ok,
       %{
         episode_id: episode_id,
         entities: Map.keys(entity_map),
         relationships: length(extraction.relationships)
       }}
    else
      {:error, reason} = err ->
        Logger.error("Ingestion pipeline failed: #{inspect(reason)}")
        err
    end
  end

  defp create_episode(agent_id, user_id, project_id, text, role, now) do
    case Client.query("CreateEpisode", %{
           content: text,
           role: role,
           source: "conversation",
           agent_id: agent_id,
           user_id: user_id,
           project_id: project_id,
           now: now
         }) do
      {:ok, %{"episode" => %{"id" => id}}} -> {:ok, id}
      {:ok, response} -> extract_id(response)
      error -> error
    end
  end

  defp store_episode_embedding(agent_id, user_id, project_id, episode_id, text) do
    with {:ok, vector} <- Embeddings.embed(text),
         {:ok, _} <-
           Client.query("StoreEpisodeEmbedding", %{
             episode_id: episode_id,
             content_summary: text,
             agent_id: agent_id,
             user_id: user_id,
             project_id: project_id,
             vector: vector,
             now: DateTime.utc_now() |> DateTime.to_iso8601()
           }) do
      :ok
    end
  end

  defp resolve_entities(entities, now) do
    entity_map =
      Enum.reduce_while(entities, {:ok, %{}}, fn entity, {:ok, acc} ->
        case resolve_single_entity(entity, now) do
          {:ok, id} -> {:cont, {:ok, Map.put(acc, entity["name"], id)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    entity_map
  end

  defp resolve_single_entity(entity, now) do
    embed_text = "#{entity["name"]}: #{entity["description"]}"

    with {:ok, vector} <- Embeddings.embed(embed_text) do
      resolve_with_vector(entity, vector, now)
    end
  end

  defp resolve_with_vector(entity, vector, now) do
    case Client.query("FindEntity", %{query_vector: vector, limit: 1}) do
      {:ok, results} -> resolve_or_create(entity, results, vector, now)
      {:error, _} -> create_new_entity(entity, vector, now)
    end
  end

  defp resolve_or_create(entity, results, vector, now) do
    case find_matching_entity(results) do
      {:match, existing_id} ->
        Logger.debug("Entity resolved to existing: #{entity["name"]} → #{existing_id}")
        {:ok, existing_id}

      :no_match ->
        create_new_entity(entity, vector, now)
    end
  end

  defp find_matching_entity(%{"embeddings" => [%{"score" => score, "id" => id} | _]})
       when score >= @entity_similarity_threshold,
       do: {:match, id}

  defp find_matching_entity(%{"results" => [%{"score" => score, "id" => id} | _]})
       when score >= @entity_similarity_threshold,
       do: {:match, id}

  defp find_matching_entity(_), do: :no_match

  defp create_new_entity(entity, vector, now) do
    with {:ok, response} <-
           Client.query("CreateEntity", %{
             name: entity["name"],
             entity_type: entity["type"],
             description: entity["description"],
             summary: entity["description"],
             now: now
           }),
         {:ok, entity_id} <- extract_id(response),
         {:ok, _} <-
           Client.query("StoreEntityEmbedding", %{
             entity_id: entity_id,
             entity_name: entity["name"],
             entity_description: entity["description"],
             vector: vector,
             now: now
           }) do
      {:ok, entity_id}
    end
  end

  defp store_facts(relationships, entity_map, now) do
    Enum.each(relationships, fn rel ->
      store_single_fact(rel, entity_map, now)
    end)

    :ok
  end

  defp store_single_fact(rel, entity_map, now) do
    source_id = Map.get(entity_map, rel["source"])
    target_id = Map.get(entity_map, rel["target"])

    if source_id && target_id do
      with {:ok, _} <- create_fact(rel, source_id, target_id, now) do
        embed_fact(rel, source_id)
      end
    else
      Logger.warning(
        "Skipping relationship: missing entity - source=#{rel["source"]} target=#{rel["target"]}"
      )
    end
  end

  defp create_fact(rel, source_id, target_id, now) do
    Client.query("CreateFact", %{
      source_id: source_id,
      target_id: target_id,
      fact_type: rel["type"],
      description: rel["description"],
      confidence: rel["confidence"] || "MEDIUM",
      now: now
    })
  end

  defp embed_fact(rel, source_id) do
    embed_text = "#{rel["source"]} #{rel["type"]} #{rel["target"]}: #{rel["description"]}"

    case Embeddings.embed(embed_text) do
      {:ok, vector} ->
        Client.query("StoreFactEmbedding", %{
          entity_id: source_id,
          fact_description: rel["description"],
          source_entity: rel["source"],
          target_entity: rel["target"],
          vector: vector,
          now: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      _ ->
        :ok
    end
  end

  defp link_entities_to_episode(entity_map, episode_id, extraction) do
    Enum.each(entity_map, fn {name, entity_id} ->
      confidence = find_entity_confidence(name, extraction.relationships)

      Client.query("LinkEntityToEpisode", %{
        entity_id: entity_id,
        episode_id: episode_id,
        confidence: confidence
      })
    end)

    :ok
  end

  defp find_entity_confidence(name, relationships) do
    Enum.find_value(relationships, "MEDIUM", fn rel ->
      if rel["source"] == name || rel["target"] == name, do: rel["confidence"]
    end)
  end

  defp extract_id(response) when is_map(response) do
    cond do
      is_binary(response["id"]) ->
        {:ok, response["id"]}

      is_map(response["data"]) && is_binary(response["data"]["id"]) ->
        {:ok, response["data"]["id"]}

      true ->
        case find_nested_id(response) do
          nil -> {:error, {:missing_id, response}}
          id -> {:ok, id}
        end
    end
  end

  defp find_nested_id(map) when is_map(map) do
    case Map.get(map, "id") do
      id when is_binary(id) -> id
      _ -> Enum.find_value(Map.values(map), &find_nested_id/1)
    end
  end

  defp find_nested_id(list) when is_list(list), do: Enum.find_value(list, &find_nested_id/1)
  defp find_nested_id(_), do: nil

  # --- Agent-scoped cleanup (episodes only; entities/facts are shared) ---

  @batch_size 500
  @zero_vector List.duplicate(0.0, 1536)

  defp do_delete_by_field(field, value) do
    deleted = delete_episode_embeddings_by(field, value)

    Logger.info("KnowledgeGraph: deleted #{deleted} episode embeddings for #{field}=#{value}")
    {:ok, deleted}
  rescue
    e ->
      Logger.warning("KnowledgeGraph cleanup failed for #{field}=#{value}: #{inspect(e)}")
      {:ok, 0}
  end

  defp delete_episode_embeddings_by(field, value, total_deleted \\ 0) do
    case Client.query("SearchEpisodes", %{query_vector: @zero_vector, limit: @batch_size}) do
      {:ok, response} ->
        ids =
          response
          |> parse_episode_results()
          |> Enum.filter(fn r ->
            r_val = r[field] || get_in(r, ["properties", field])
            r_val == value
          end)
          |> Enum.map(fn r -> r["id"] || get_in(r, ["properties", "id"]) end)
          |> Enum.reject(&is_nil/1)

        Enum.each(ids, &Client.query("DeleteMemory", %{id: &1}))

        if ids == [] do
          total_deleted
        else
          delete_episode_embeddings_by(field, value, total_deleted + length(ids))
        end

      {:error, _} ->
        total_deleted
    end
  end

  defp parse_episode_results(%{"results" => results}) when is_list(results), do: results
  defp parse_episode_results(%{"embeddings" => results}) when is_list(results), do: results
  defp parse_episode_results(results) when is_list(results), do: results
  defp parse_episode_results(_), do: []

  # --- Direct queries (entities are shared, no agent scope needed) ---

  defp do_query_entity(name), do: find_and_query(name, "GetEntityKnowledge")

  defp do_query_related(name, _hops), do: find_and_query(name, "GetRelatedEntities")

  defp find_and_query(name, query_name) do
    with {:ok, vector} <- Embeddings.embed(name),
         {:ok, results} <- Client.query("FindEntity", %{query_vector: vector, limit: 1}) do
      case find_matching_entity(results) do
        {:match, entity_id} -> Client.query(query_name, %{entity_id: entity_id})
        :no_match -> {:ok, :not_found}
      end
    end
  end
end
