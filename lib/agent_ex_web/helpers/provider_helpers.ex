defmodule AgentExWeb.ProviderHelpers do
  @moduledoc """
  Shared provider/model data for chat and settings pages.
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

  def models_for_provider(provider), do: Map.get(@models_by_provider, provider, [])

  def provider_options,
    do: [{"OpenAI", "openai"}, {"Anthropic", "anthropic"}, {"Moonshot", "moonshot"}]

  def default_model_for("openai"), do: "gpt-4o-mini"
  def default_model_for("anthropic"), do: "claude-haiku-4-5-20251001"
  def default_model_for("moonshot"), do: "moonshot-v1-8k"
  def default_model_for(_), do: "gpt-4o-mini"
end
