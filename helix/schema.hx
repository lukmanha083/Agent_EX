// === VECTORS (for semantic search) ===
V::Memory {
    content: String,
    memory_type: String,
    agent_id: String,
    user_id: String,
    project_id: String,
    session_id: String,
    created_at: String
}

V::EntityEmbedding {
    entity_name: String,
    entity_description: String
}

V::EpisodeEmbedding {
    content_summary: String,
    agent_id: String,
    user_id: String,
    project_id: String
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
    user_id: String,
    project_id: String,
    occurred_at: String
}

// === EDGES (relationships) ===
E::Fact {
    From: Entity,
    To: Entity,
    Properties: {
        fact_type: String,
        description: String,
        confidence: String,
        t_valid: String,
        t_invalid: String
    }
}

E::MentionedIn {
    From: Entity,
    To: Episode,
    Properties: {
        extraction_confidence: String
    }
}

E::HasEmbedding {
    From: Entity,
    To: EntityEmbedding,
    Properties: {
        linked_at: String
    }
}

E::HasEpisodeEmbedding {
    From: Episode,
    To: EpisodeEmbedding,
    Properties: {
        linked_at: String
    }
}

E::HasFactEmbedding {
    From: Entity,
    To: FactEmbedding,
    Properties: {
        linked_at: String
    }
}
