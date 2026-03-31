defmodule AgentEx.ProviderHelpers do
  @moduledoc """
  Single source of truth for provider/model data.
  Used by User changeset validation, ChatLive, Settings, and runtime token budgets.
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

  # Context window sizes per model (in tokens)
  @context_windows %{
    # OpenAI
    "gpt-4o" => 128_000,
    "gpt-4o-mini" => 128_000,
    "gpt-5.4" => 256_000,
    "gpt-5.4-mini" => 256_000,
    "gpt-5.4-nano" => 128_000,
    "gpt-5.4-pro" => 256_000,
    "o3-mini" => 200_000,
    # Anthropic
    "claude-sonnet-4-5-20250514" => 200_000,
    "claude-haiku-4-5-20251001" => 200_000,
    "claude-opus-4-20250514" => 200_000,
    # Moonshot
    "moonshot-v1-8k" => 8_000,
    "moonshot-v1-32k" => 32_000,
    "moonshot-v1-128k" => 128_000
  }

  @default_context_window 32_000

  @valid_providers Map.keys(@models_by_provider)

  @provider_atoms %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "moonshot" => :moonshot
  }

  @provider_labels %{
    "openai" => "OpenAI",
    "anthropic" => "Anthropic",
    "moonshot" => "Moonshot"
  }

  def valid_providers, do: @valid_providers

  def models_for_provider(provider), do: Map.get(@models_by_provider, provider, [])

  def valid_model?(provider, model), do: model in models_for_provider(provider)

  def provider_to_atom(provider), do: Map.get(@provider_atoms, provider, :openai)

  # CoreComponents select uses {value, label} order
  def provider_options do
    Enum.map(@valid_providers, fn provider ->
      {provider, Map.fetch!(@provider_labels, provider)}
    end)
  end

  @doc "Get the context window size for a model (in tokens)."
  @spec context_window_for(String.t()) :: pos_integer()
  def context_window_for(model) when is_binary(model) do
    Map.get(@context_windows, model, @default_context_window)
  end

  def context_window_for(_), do: @default_context_window

  @doc "Format context window for display (e.g. '128K', '200K')."
  @spec format_context_window(pos_integer()) :: String.t()
  def format_context_window(tokens) when tokens >= 1_000_000 do
    "#{Float.round(tokens / 1_000_000, 1)}M"
  end

  def format_context_window(tokens) when tokens >= 1_000 do
    "#{div(tokens, 1_000)}K"
  end

  def format_context_window(tokens), do: "#{tokens}"

  def default_model_for("openai"), do: "gpt-4o-mini"
  def default_model_for("anthropic"), do: "claude-haiku-4-5-20251001"
  def default_model_for("moonshot"), do: "moonshot-v1-8k"
  def default_model_for(_), do: "gpt-4o-mini"
end
