// --- Tier 3: Basic vector memory ---
QUERY SearchMemory(vector: [F64], limit: I64) =>
    results <- SearchV<Memory>(vector, limit)
    RETURN results

QUERY AddMemory(vector: [F64], content: String, memory_type: String, agent_id: String, user_id: String, project_id: String, session_id: String) =>
    mem <- AddV<Memory>(vector, { content: content, memory_type: memory_type, agent_id: agent_id, user_id: user_id, project_id: project_id, session_id: session_id })
    RETURN mem

QUERY DeleteMemory(id: ID) =>
    DROP V<Memory>(id)
    RETURN NONE

QUERY DeleteEpisodeEmbedding(id: ID) =>
    DROP V<EpisodeEmbedding>(id)
    RETURN NONE

// --- Knowledge Graph: Create ---
QUERY CreateEntity(name: String, entity_type: String, description: String, summary: String, now: String) =>
    entity <- AddN<Entity>({
        name: name, entity_type: entity_type,
        description: description, summary: summary,
        first_seen: now, last_seen: now
    })
    RETURN entity

QUERY CreateEpisode(content: String, role: String, source: String, agent_id: String, user_id: String, project_id: String, now: String) =>
    episode <- AddN<Episode>({
        content: content, role: role, source: source, agent_id: agent_id, user_id: user_id, project_id: project_id, occurred_at: now
    })
    RETURN episode

QUERY CreateFact(source_id: ID, target_id: ID, fact_type: String, description: String, confidence: String, now: String) =>
    fact <- AddE<Fact>({
        fact_type: fact_type, description: description,
        confidence: confidence, t_valid: now, t_invalid: ""
    })::From(source_id)::To(target_id)
    RETURN fact

QUERY LinkEntityToEpisode(entity_id: ID, episode_id: ID, confidence: String) =>
    link <- AddE<MentionedIn>({ extraction_confidence: confidence })::From(entity_id)::To(episode_id)
    RETURN link

// --- Knowledge Graph: Embeddings ---
QUERY StoreEntityEmbedding(entity_id: ID, entity_name: String, entity_description: String, vector: [F64], now: String) =>
    emb <- AddV<EntityEmbedding>(vector, { entity_name: entity_name, entity_description: entity_description })
    link <- AddE<HasEmbedding>({ linked_at: now })::From(entity_id)::To(emb)
    RETURN emb

QUERY StoreEpisodeEmbedding(episode_id: ID, content_summary: String, agent_id: String, user_id: String, project_id: String, vector: [F64], now: String) =>
    emb <- AddV<EpisodeEmbedding>(vector, { content_summary: content_summary, agent_id: agent_id, user_id: user_id, project_id: project_id })
    link <- AddE<HasEpisodeEmbedding>({ linked_at: now })::From(episode_id)::To(emb)
    RETURN emb

QUERY StoreFactEmbedding(entity_id: ID, fact_description: String, source_entity: String, target_entity: String, vector: [F64], now: String) =>
    emb <- AddV<FactEmbedding>(vector, { fact_description: fact_description, source_entity: source_entity, target_entity: target_entity })
    link <- AddE<HasFactEmbedding>({ linked_at: now })::From(entity_id)::To(emb)
    RETURN emb

// --- Knowledge Graph: Retrieval ---
QUERY FindEntity(query_vector: [F64], limit: I64) =>
    embeddings <- SearchV<EntityEmbedding>(query_vector, limit)
    RETURN embeddings

QUERY GetEntityKnowledge(entity_id: ID) =>
    entity <- N<Entity>(entity_id)
    outgoing <- entity::Out<Fact>
    incoming <- entity::In<Fact>
    RETURN entity, outgoing, incoming

QUERY GetRelatedEntities(entity_id: ID) =>
    entity <- N<Entity>(entity_id)
    outgoing <- entity::Out<Fact>
    incoming <- entity::In<Fact>
    RETURN outgoing, incoming

QUERY SearchEpisodes(query_vector: [F64], limit: I64) =>
    embeddings <- SearchV<EpisodeEmbedding>(query_vector, limit)
    RETURN embeddings

QUERY SearchFacts(query_vector: [F64], limit: I64) =>
    embeddings <- SearchV<FactEmbedding>(query_vector, limit)
    RETURN embeddings

QUERY HybridEntitySearch(query_vector: [F64], limit: I64) =>
    entity_embeddings <- SearchV<EntityEmbedding>(query_vector, limit)
    entities <- entity_embeddings::In<HasEmbedding>
    related <- entities::Out<Fact>
    RETURN entities, related
