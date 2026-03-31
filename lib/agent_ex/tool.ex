defmodule AgentEx.Tool do
  @moduledoc """
  Defines a tool that agents can use.

  Maps to AutoGen's `Tool` / `FunctionTool` / `ToolSchema`.

  Supports three kinds:
  - `:read` — sensing tools (auto-approved, like `r--` in Linux)
  - `:write` — acting tools (can be gated by intervention, like `-w-`)
  - `:builtin` — provider-executed server-side tools (no local function)

  ## Example

      AgentEx.Tool.new(
        name: "get_weather",
        description: "Get the current weather for a location",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["location"]
        },
        function: fn %{"location" => loc} -> {:ok, "Sunny, 25°C in \#{loc}"} end
      )

      # Built-in provider tool (executed server-side)
      AgentEx.Tool.builtin("$web_search")
  """

  @enforce_keys [:name]
  defstruct [:name, :description, :parameters, :function, :type, kind: :read]

  @type kind :: :read | :write | :builtin

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          parameters: map() | nil,
          function: (map() -> {:ok, term()} | {:error, term()}) | nil,
          kind: kind(),
          type: String.t() | nil
        }

  @doc """
  Create a new tool.

  ## Options
  - `:kind` — `:read` (default) or `:write`. Read tools gather information
    (sensing), write tools change the world (acting). Like Linux file
    permissions: read tools are auto-approved, write tools can be gated
    by an `AgentEx.Intervention` handler.
  """
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Create a built-in provider tool (executed server-side, no local function).

  ## Options
  - `:type` — provider-specific type string (e.g., `"web_search_20260209"` for Anthropic)
  - `:description` — optional description
  """
  def builtin(name, opts \\ []) do
    %__MODULE__{
      name: name,
      description: Keyword.get(opts, :description),
      parameters: nil,
      function: nil,
      kind: Keyword.get(opts, :kind, :builtin),
      type: Keyword.get(opts, :type)
    }
  end

  @doc "Returns true if the tool has side effects (write/acting tool)."
  def write?(%__MODULE__{kind: :write}), do: true
  def write?(%__MODULE__{}), do: false

  @doc "Returns true if the tool is read-only (sensing tool)."
  def read?(%__MODULE__{kind: :read}), do: true
  def read?(%__MODULE__{}), do: false

  @doc "Returns true if the tool is a provider built-in."
  def builtin?(%__MODULE__{kind: :builtin}), do: true
  def builtin?(%__MODULE__{}), do: false

  @doc "Convert to OpenAI tool schema format (default, no provider context)."
  def to_schema(%__MODULE__{} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }
    }
  end

  @doc "Convert to provider-specific tool schema."
  def to_schema(%__MODULE__{kind: :builtin} = tool, :moonshot) do
    %{"type" => "builtin_function", "function" => %{"name" => tool.name}}
  end

  def to_schema(%__MODULE__{kind: :builtin} = tool, :anthropic) do
    %{"type" => tool.type || tool.name, "name" => tool.name}
  end

  def to_schema(%__MODULE__{kind: :builtin} = tool, _provider) do
    %{"type" => tool.name}
  end

  def to_schema(%__MODULE__{} = tool, :anthropic) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => tool.parameters
    }
  end

  def to_schema(%__MODULE__{} = tool, _provider), do: to_schema(tool)

  @doc "Execute the tool with the given arguments."
  def execute(%__MODULE__{kind: :builtin}, _arguments) do
    {:error, "built-in tools are executed server-side by the provider"}
  end

  def execute(%__MODULE__{function: func}, arguments) when is_map(arguments) do
    func.(arguments)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
