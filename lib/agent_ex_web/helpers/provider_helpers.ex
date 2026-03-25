defmodule AgentExWeb.ProviderHelpers do
  @moduledoc """
  Single source of truth for provider/model data.
  Used by ChatLive, Settings, and User changeset validation.
  """

  @models_by_provider %{
    "openai" => [
      "gpt-4o",
      "gpt-4o-mini",
      "gpt-5.4",
      "gpt-5.4-mini",
      "gpt-5.4-nano",
      "gpt-5.4-pro",
      "o3-mini"
    ],
    "anthropic" => [
      "claude-sonnet-4-5-20250514",
      "claude-haiku-4-5-20251001",
      "claude-opus-4-20250514"
    ],
    "moonshot" => ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"]
  }

  @valid_providers Map.keys(@models_by_provider)

  @provider_atoms %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "moonshot" => :moonshot
  }

  def valid_providers, do: @valid_providers

  def models_for_provider(provider), do: Map.get(@models_by_provider, provider, [])

  def valid_model?(provider, model), do: model in models_for_provider(provider)

  def provider_to_atom(provider), do: Map.get(@provider_atoms, provider, :openai)

  # CoreComponents select uses {value, label} order
  def provider_options,
    do: [{"openai", "OpenAI"}, {"anthropic", "Anthropic"}, {"moonshot", "Moonshot"}]

  def default_model_for("openai"), do: "gpt-4o-mini"
  def default_model_for("anthropic"), do: "claude-haiku-4-5-20251001"
  def default_model_for("moonshot"), do: "moonshot-v1-8k"
  def default_model_for(_), do: "gpt-4o-mini"
end
