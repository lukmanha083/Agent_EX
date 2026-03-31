defmodule AgentEx.ProviderTools do
  @moduledoc """
  Hardcoded registry of built-in provider tools per LLM provider.

  Each provider offers server-side tools that are activated by including them
  in the API request. These are not user-defined — they're fixed capabilities
  of the provider's API.

  Only tools compatible with our ModelClient API paths are listed:
  - Anthropic: Messages API (`/v1/messages`) — rich builtin support
  - OpenAI: Chat Completions API (`/chat/completions`) — no server-side builtins
  - Moonshot: Chat Completions compatible — `$web_search` builtin

  All builtins are enabled by default. Users can disable individual ones
  via `AgentConfig.disabled_builtins` (per agent) or `User.disabled_builtins`
  (for the chat orchestrator).
  """

  alias AgentEx.Tool

  @type builtin_spec :: %{
          name: String.t(),
          type: String.t(),
          description: String.t(),
          kind: :read | :write
        }

  # Anthropic Messages API builtins — all work with our ModelClient
  # computer_use omitted: requires display_width_px/display_height_px config
  @anthropic_builtins [
    %{
      name: "web_search",
      type: "web_search_20250305",
      description: "Search the web for current information",
      kind: :read
    },
    %{
      name: "code_execution",
      type: "code_execution_20250522",
      description: "Execute Python code in a sandboxed environment",
      kind: :write
    },
    %{
      name: "text_editor",
      type: "text_editor_20250429",
      description: "View and edit text files with find-and-replace",
      kind: :write
    }
  ]

  # OpenAI Chat Completions API has no server-side builtins.
  # web_search_preview, code_interpreter, file_search are Responses API only.
  @openai_builtins []

  # Moonshot Chat Completions compatible builtins
  @moonshot_builtins [
    %{
      name: "$web_search",
      type: "builtin_function",
      description: "Search the web using Moonshot's built-in search",
      kind: :read
    }
  ]

  @builtins_by_provider %{
    "anthropic" => @anthropic_builtins,
    "openai" => @openai_builtins,
    "moonshot" => @moonshot_builtins
  }

  @doc "List all available builtin tool specs for a provider."
  @spec list(String.t()) :: [builtin_spec()]
  def list(provider) do
    Map.get(@builtins_by_provider, provider, [])
  end

  @doc "List builtin tool names for a provider."
  @spec names(String.t()) :: [String.t()]
  def names(provider) do
    list(provider) |> Enum.map(& &1.name)
  end

  @doc """
  Build `%Tool{}` structs for enabled builtins.
  Filters out any names in `disabled_builtins`.
  """
  @spec enabled_tools(String.t(), [String.t()]) :: [Tool.t()]
  def enabled_tools(provider, disabled_builtins \\ []) do
    disabled = MapSet.new(disabled_builtins)

    list(provider)
    |> Enum.reject(fn spec -> MapSet.member?(disabled, spec.name) end)
    |> Enum.map(fn spec ->
      Tool.builtin(spec.name, type: spec.type, description: spec.description)
    end)
  end

  @doc """
  Build `%Tool{}` structs for read-only builtins (for orchestrator use).
  Only includes tools classified as `:read` kind.
  """
  @spec read_only_tools(String.t(), [String.t()]) :: [Tool.t()]
  def read_only_tools(provider, disabled_builtins \\ []) do
    disabled = MapSet.new(disabled_builtins)

    list(provider)
    |> Enum.reject(fn spec -> MapSet.member?(disabled, spec.name) end)
    |> Enum.filter(fn spec -> spec.kind == :read end)
    |> Enum.map(fn spec ->
      Tool.builtin(spec.name, type: spec.type, description: spec.description)
    end)
  end

  @doc "Returns true if the provider has any builtin tools."
  @spec has_builtins?(String.t()) :: boolean()
  def has_builtins?(provider) do
    list(provider) != []
  end
end
