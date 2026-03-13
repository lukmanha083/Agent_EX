defmodule AgentEx.Tool do
  @moduledoc """
  Defines a tool that agents can use.

  Maps to AutoGen's `Tool` / `FunctionTool` / `ToolSchema`.

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
  """

  @enforce_keys [:name, :description, :parameters, :function]
  defstruct [:name, :description, :parameters, :function, kind: :read]

  @type kind :: :read | :write

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          function: (map() -> {:ok, term()} | {:error, term()}),
          kind: kind()
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

  @doc "Returns true if the tool has side effects (write/acting tool)."
  def write?(%__MODULE__{kind: :write}), do: true
  def write?(%__MODULE__{}), do: false

  @doc "Returns true if the tool is read-only (sensing tool)."
  def read?(%__MODULE__{kind: :read}), do: true
  def read?(%__MODULE__{}), do: false

  @doc "Convert to the OpenAI tool schema format for LLM API calls."
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

  @doc "Execute the tool with the given arguments."
  def execute(%__MODULE__{function: func}, arguments) when is_map(arguments) do
    func.(arguments)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
