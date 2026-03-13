defmodule AgentEx.Memory.KnowledgeGraph.Extractor do
  @moduledoc """
  LLM-based entity and relationship extraction from conversation text.
  Reuses `AgentEx.ModelClient` for the chat completion call.
  """

  alias AgentEx.{Message, ModelClient}

  require Logger

  @extraction_prompt """
  Extract entities and relationships from the following conversation message.

  Entity types: PERSON, ORGANIZATION, CONCEPT, EVENT, ARTIFACT, PREFERENCE

  For each entity, provide:
  - name: canonical name
  - type: one of the entity types above
  - description: brief description based on context

  For each relationship, provide:
  - source: source entity name
  - target: target entity name
  - type: verb phrase describing the relationship (e.g., "works_at", "uses", "prefers")
  - description: brief description of the relationship
  - confidence: HIGH, MEDIUM, or LOW

  Output ONLY valid JSON with this exact structure:
  {
    "entities": [{"name": "...", "type": "...", "description": "..."}],
    "relationships": [{"source": "...", "target": "...", "type": "...", "description": "...", "confidence": "..."}]
  }

  If no entities or relationships can be extracted, return:
  {"entities": [], "relationships": []}
  """

  def extract(text) when is_binary(text) do
    model = Application.get_env(:agent_ex, :extraction_model, "gpt-4o-mini")
    client = ModelClient.new(model: model)

    messages = [
      Message.system(@extraction_prompt),
      Message.user(text)
    ]

    case ModelClient.create(client, messages,
           temperature: 0.0,
           response_format: %{"type" => "json_object"}
         ) do
      {:ok, %Message{content: content}} ->
        parse_extraction(content)

      {:error, reason} ->
        Logger.error("Extraction LLM error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_extraction(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"entities" => entities, "relationships" => relationships}} ->
        {:ok, %{entities: entities, relationships: relationships}}

      {:ok, _other} ->
        {:ok, %{entities: [], relationships: []}}

      {:error, reason} ->
        Logger.error("Failed to parse extraction JSON: #{inspect(reason)}")
        {:error, :parse_error}
    end
  end
end
