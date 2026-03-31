defmodule AgentExWeb.ProviderHelpers do
  @moduledoc false
  # Deprecated: use AgentEx.ProviderHelpers directly.
  # This module delegates to the core context for backwards compatibility.

  defdelegate valid_providers, to: AgentEx.ProviderHelpers
  defdelegate models_for_provider(provider), to: AgentEx.ProviderHelpers
  defdelegate valid_model?(provider, model), to: AgentEx.ProviderHelpers
  defdelegate provider_to_atom(provider), to: AgentEx.ProviderHelpers
  defdelegate provider_options, to: AgentEx.ProviderHelpers
  defdelegate default_model_for(provider), to: AgentEx.ProviderHelpers
  defdelegate context_window_for(model), to: AgentEx.ProviderHelpers
  defdelegate format_context_window(tokens), to: AgentEx.ProviderHelpers
end
