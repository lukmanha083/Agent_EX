// === VECTORS (for semantic search) ===
V::Memory {
    content: String,
    type: String,
    agent_id: String,
    session_id: String,
    created_at: String
}

V::EntityEmbedding {
    entity_name: String,
    entity_description: String
}

V::EpisodeEmbedding {
    content_summary: String,
    agent_id: String
}

V::FactEmbedding {
    fact_description: String,
    source_entity: String,
    target_entity: String
}

// === NODES (knowledge graph) ===
N::Entity {
    name: String,
    entity_type: String,
    description: String,
    summary: String,
    first_seen: String,
    last_seen: String
}

N::Episode {
    content: String,
    role: String,
    source: String,
    agent_id: String,
    occurred_at: String
}

// === EDGES (relationships) ===
E::Fact {
    fact_type: String,
    description: String,
    confidence: String,
    t_valid: String,
    t_invalid: String
}

E::MentionedIn {
    extraction_confidence: String
}

E::HasEmbedding {}
E::HasEpisodeEmbedding {}
E::HasFactEmbedding {}
