defmodule AgentEx.Memory.KnowledgeGraph.Store do
  @moduledoc """
  Orchestrates knowledge graph operations using Postgres + pgvector.

  - **Episodes** are per-project, per-agent (conversation turns are separate)
  - **Entities** are shared (world knowledge is universal across agents)
  - **Facts** are shared (relationships between entities are universal)
  - **Retrieval** filters episodes by project/agent while facts are shared
  """

  @behaviour AgentEx.Memory.Tier

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias AgentEx.Memory.Embeddings
  alias AgentEx.Memory.KnowledgeGraph.{Entity, Episode, Extractor, Fact, Mention, Retriever}
  alias AgentEx.Repo

  require Logger

  @entity_distance_threshold 0.15

  # --- Public API ---

  def ingest(project_id, agent_id, text, role \\ "user") do
    run_ingestion_pipeline(project_id, agent_id, text, role)
  end

  def query_entity(name) do
    do_query_entity(name)
  end

  def query_related(name, hops \\ 1) do
    if hops > 1 do
      Logger.warning(
        "query_related: multi-hop traversal not yet implemented, returning single-hop"
      )
    end

    do_query_related(name)
  end

  def hybrid_search(project_id, agent_id, query, limit \\ 5) do
    Retriever.hybrid_search(project_id, agent_id, query, limit)
  end

  @doc """
  Delete all episodes for an agent within a project.
  Entities and facts are shared and NOT deleted.
  Mentions are cleaned up by CASCADE from episodes.
  """
  def delete_by_agent(project_id, agent_id) do
    {count, _} =
      from(e in Episode,
        where: e.project_id == ^project_id and e.agent_id == ^agent_id
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc "Delete all episodes for a project. (Also handled by CASCADE.)"
  def delete_by_project(project_id) do
    {count, _} =
      from(e in Episode, where: e.project_id == ^project_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Delete orphaned entities that have no remaining mentions or facts.

  Entities are shared across projects, so they are not deleted by CASCADE.
  After a project is deleted, entities that were only referenced by that
  project's episodes become orphaned. This function cleans them up.

  Returns `{:ok, count}` with the number of deleted entities.
  """
  def cleanup_orphaned_entities do
    mention_exists = from(m in Mention, where: m.entity_id == parent_as(:entity).id)
    source_fact_exists = from(f in Fact, where: f.source_entity_id == parent_as(:entity).id)
    target_fact_exists = from(f in Fact, where: f.target_entity_id == parent_as(:entity).id)

    {count, _} =
      from(e in Entity,
        as: :entity,
        where:
          not exists(mention_exists) and
            not exists(source_fact_exists) and
            not exists(target_fact_exists)
      )
      |> Repo.delete_all()

    if count > 0 do
      Logger.info("KnowledgeGraph: cleaned up #{count} orphaned entities")
    end

    {:ok, count}
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages({_user_id, project_id, agent_id}, query) when is_binary(query) do
    case hybrid_search(project_id, agent_id, query) do
      {:ok, context} when context != "" ->
        [%{role: "system", content: "## Knowledge Graph\n#{context}"}]

      _ ->
        []
    end
  end

  @impl AgentEx.Memory.Tier
  def token_estimate({_user_id, project_id, agent_id}, query) when is_binary(query) do
    case hybrid_search(project_id, agent_id, query) do
      {:ok, context} -> div(String.length(context), 4)
      _ -> 0
    end
  end

  # --- Ingestion Pipeline ---

  defp run_ingestion_pipeline(project_id, agent_id, text, role) do
    # Extract entities/relationships before DB writes so LLM failures
    # don't leave orphan episodes
    case Extractor.extract(text) do
      {:ok, extraction} ->
        do_ingest_transaction(project_id, agent_id, text, role, extraction)

      {:error, reason} = err ->
        Logger.error("Ingestion extraction failed: #{inspect(reason)}")
        err
    end
  end

  defp do_ingest_transaction(project_id, agent_id, text, role, extraction) do
    Repo.transaction(fn ->
      with {:ok, episode} <- create_episode(project_id, agent_id, text, role),
           {:ok, entity_map} <- resolve_entities(extraction.entities),
           :ok <- store_facts(extraction.relationships, entity_map),
           :ok <- link_entities_to_episode(entity_map, episode.id, extraction) do
        %{
          episode_id: episode.id,
          entities: Map.keys(entity_map),
          relationships: length(extraction.relationships)
        }
      else
        {:error, reason} ->
          Logger.error("Ingestion pipeline failed: #{inspect(reason)}")
          Repo.rollback(reason)
      end
    end)
  end

  defp create_episode(project_id, agent_id, text, role) do
    embedding = embed_or_nil(text)

    %Episode{}
    |> Episode.changeset(%{
      project_id: project_id,
      agent_id: agent_id,
      content: text,
      role: role,
      source: "conversation",
      content_embedding: embedding
    })
    |> Repo.insert()
  end

  defp resolve_entities(entities) do
    entity_map =
      Enum.reduce_while(entities, {:ok, %{}}, fn entity, {:ok, acc} ->
        case resolve_single_entity(entity) do
          {:ok, db_entity} -> {:cont, {:ok, Map.put(acc, entity["name"], db_entity.id)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    entity_map
  end

  defp resolve_single_entity(entity) do
    embed_text = "#{entity["name"]}: #{entity["description"]}"

    case Embeddings.embed(embed_text) do
      {:ok, vector} -> resolve_with_vector(entity, vector)
      {:error, _} = err -> err
    end
  end

  defp resolve_with_vector(entity, vector) do
    entity_type = entity["type"]

    # Find closest existing entity by vector similarity, scoped to same type
    existing =
      from(e in Entity,
        where: not is_nil(e.name_embedding) and e.entity_type == ^entity_type,
        order_by: cosine_distance(e.name_embedding, ^vector),
        limit: 1,
        select: %{id: e.id, distance: cosine_distance(e.name_embedding, ^vector)}
      )
      |> Repo.one()

    if existing && existing.distance <= @entity_distance_threshold do
      # Update existing entity's description
      entity_record = Repo.get!(Entity, existing.id)

      entity_record
      |> Entity.changeset(%{description: entity["description"]})
      |> Repo.update()
    else
      # Create new entity
      %Entity{}
      |> Entity.changeset(%{
        name: entity["name"],
        entity_type: entity["type"],
        description: entity["description"],
        summary: entity["description"],
        name_embedding: vector
      })
      |> Repo.insert(
        on_conflict: {:replace, [:description, :summary, :name_embedding, :updated_at]},
        conflict_target: [:name, :entity_type]
      )
    end
  end

  defp store_facts(relationships, entity_map) do
    Enum.each(relationships, fn rel ->
      store_single_fact(rel, entity_map)
    end)

    :ok
  end

  defp store_single_fact(rel, entity_map) do
    source_id = Map.get(entity_map, rel["source"])
    target_id = Map.get(entity_map, rel["target"])

    if source_id && target_id do
      embedding =
        embed_or_nil("#{rel["source"]} #{rel["type"]} #{rel["target"]}: #{rel["description"]}")

      result =
        %Fact{}
        |> Fact.changeset(%{
          source_entity_id: source_id,
          target_entity_id: target_id,
          fact_type: rel["type"],
          description: rel["description"],
          confidence: rel["confidence"] || "MEDIUM",
          description_embedding: embedding
        })
        |> Repo.insert(
          on_conflict:
            {:replace, [:description, :confidence, :description_embedding, :updated_at]},
          conflict_target: [:source_entity_id, :target_entity_id, :fact_type]
        )

      case result do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.warning(
            "Failed to store fact #{rel["source"]}→#{rel["target"]}: #{inspect(changeset.errors)}"
          )
      end
    else
      Logger.warning(
        "Skipping relationship: missing entity - source=#{rel["source"]} target=#{rel["target"]}"
      )
    end
  end

  defp link_entities_to_episode(entity_map, episode_id, extraction) do
    Enum.each(entity_map, fn {name, entity_id} ->
      confidence = find_entity_confidence(name, extraction.relationships)

      %Mention{}
      |> Mention.changeset(%{
        entity_id: entity_id,
        episode_id: episode_id,
        confidence: confidence
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:entity_id, :episode_id])
    end)

    :ok
  end

  defp find_entity_confidence(name, relationships) do
    Enum.find_value(relationships, "MEDIUM", fn rel ->
      if rel["source"] == name || rel["target"] == name, do: rel["confidence"]
    end)
  end

  # --- Direct queries (entities are shared, no project scope needed) ---

  defp do_query_entity(name) do
    case find_entity_by_name(name) do
      nil ->
        {:ok, :not_found}

      entity ->
        entity = Repo.preload(entity, [:outgoing_facts, :incoming_facts])

        {:ok,
         %{
           entity: entity,
           outgoing: Enum.map(entity.outgoing_facts, &fact_to_map/1),
           incoming: Enum.map(entity.incoming_facts, &fact_to_map/1)
         }}
    end
  end

  defp do_query_related(name) do
    case find_entity_by_name(name) do
      nil ->
        {:ok, :not_found}

      entity ->
        related =
          from(f in Fact,
            where: f.source_entity_id == ^entity.id or f.target_entity_id == ^entity.id,
            preload: [:source_entity, :target_entity]
          )
          |> Repo.all()

        {:ok, %{entity: entity, related: Enum.map(related, &fact_to_map/1)}}
    end
  end

  defp find_entity_by_name(name) do
    case Embeddings.embed(name) do
      {:ok, vector} ->
        result =
          from(e in Entity,
            where: not is_nil(e.name_embedding),
            order_by: cosine_distance(e.name_embedding, ^vector),
            limit: 1,
            select: {e, cosine_distance(e.name_embedding, ^vector)}
          )
          |> Repo.one()

        case result do
          {entity, distance} when distance <= @entity_distance_threshold -> entity
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fact_to_map(%Fact{} = f) do
    %{
      fact_type: f.fact_type,
      description: f.description,
      confidence: f.confidence,
      source_entity_id: f.source_entity_id,
      target_entity_id: f.target_entity_id
    }
  end

  defp embed_or_nil(text) do
    case Embeddings.embed(text) do
      {:ok, vector} -> vector
      _ -> nil
    end
  end
end
