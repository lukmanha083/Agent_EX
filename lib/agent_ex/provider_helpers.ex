defmodule AgentEx.ProviderHelpers do
  @moduledoc """
  Single source of truth for provider/model data.
  Used by User changeset validation, ChatLive, Settings, and runtime token budgets.
  """

  @models_by_provider %{
    "openai" => [
      "gpt-5.4",
      "gpt-5.4-mini",
      "gpt-5.4-nano",
      "o3",
      "o3-pro",
      "o3-mini",
      "o4-mini",
      "gpt-4o",
      "gpt-4o-mini"
    ],
    "anthropic" => [
      "claude-opus-4-6",
      "claude-sonnet-4-6",
      "claude-sonnet-4-5-20250514",
      "claude-haiku-4-5-20251001",
      "claude-opus-4-20250514"
    ],
    "openrouter" => [
      # Top trending
      "qwen/qwen3.6-plus",
      "deepseek/deepseek-v3.2",
      "minimax/minimax-m2.7",
      "minimax/minimax-m2.5",
      # Reasoning
      "moonshotai/kimi-k2.5",
      "deepseek/deepseek-r1",
      "x-ai/grok-4",
      # Google
      "google/gemini-2.5-flash",
      "google/gemini-2.5-pro",
      "google/gemma-4-31b-it",
      "google/gemma-4-26b-a4b-it",
      # Meta
      "meta-llama/llama-4-maverick",
      "meta-llama/llama-4-scout",
      # Other
      "deepseek/deepseek-v3.1",
      "mistralai/mistral-large-2411",
      "nvidia/llama-3.1-nemotron-ultra-253b"
    ]
  }

  # Context window sizes per model (in tokens)
  @context_windows %{
    # OpenAI
    "gpt-5.4" => 1_050_000,
    "gpt-5.4-mini" => 400_000,
    "gpt-5.4-nano" => 400_000,
    "o3" => 200_000,
    "o3-pro" => 200_000,
    "o3-mini" => 200_000,
    "o4-mini" => 200_000,
    "gpt-4o" => 128_000,
    "gpt-4o-mini" => 128_000,
    # Anthropic
    "claude-opus-4-6" => 1_000_000,
    "claude-sonnet-4-6" => 1_000_000,
    "claude-sonnet-4-5-20250514" => 200_000,
    "claude-haiku-4-5-20251001" => 200_000,
    "claude-opus-4-20250514" => 200_000,
    # OpenRouter
    "qwen/qwen3.6-plus" => 1_000_000,
    "deepseek/deepseek-v3.2" => 163_840,
    "minimax/minimax-m2.7" => 204_800,
    "minimax/minimax-m2.5" => 196_608,
    "moonshotai/kimi-k2.5" => 256_000,
    "deepseek/deepseek-r1" => 64_000,
    "x-ai/grok-4" => 256_000,
    "google/gemini-2.5-flash" => 1_048_576,
    "google/gemini-2.5-pro" => 1_048_576,
    "google/gemma-4-31b-it" => 256_000,
    "google/gemma-4-26b-a4b-it" => 256_000,
    "meta-llama/llama-4-maverick" => 1_048_576,
    "meta-llama/llama-4-scout" => 327_680,
    "deepseek/deepseek-v3.1" => 128_000,
    "mistralai/mistral-large-2411" => 128_000,
    "nvidia/llama-3.1-nemotron-ultra-253b" => 131_072
  }

  @default_context_window 32_000

  @valid_providers Map.keys(@models_by_provider)

  @provider_atoms %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "openrouter" => :openrouter
  }

  @provider_labels %{
    "openai" => "OpenAI",
    "anthropic" => "Anthropic",
    "openrouter" => "OpenRouter"
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

  def default_model_for("openai"), do: "gpt-5.4-mini"
  def default_model_for("anthropic"), do: "claude-sonnet-4-6"
  def default_model_for("openrouter"), do: "moonshotai/kimi-k2.5"
  def default_model_for(_), do: "gpt-5.4-mini"
end
