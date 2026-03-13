defmodule AgentEx.ToolBuilder do
  @moduledoc """
  Auto-generate JSON Schema for tool parameters from declarative specs.

  Maps to AutoGen's Pydantic-based schema generation. Since Elixir lacks
  Python's runtime type introspection, we use a DSL approach: param specs
  → JSON Schema.

  ## Function-based builder

      ToolBuilder.build(
        name: "get_weather",
        description: "Get weather for a city",
        params: [
          {:city, :string, "City name"},
          {:units, :string, "C or F", optional: true}
        ],
        function: &MyTools.get_weather/1
      )

  ## Macro DSL

      defmodule MyTools do
        import AgentEx.ToolBuilder

        deftool :get_weather, "Get weather for a city" do
          param :city, :string, "City name"
          param :units, :string, "C or F", optional: true
        end
      end
      # Generates `MyTools.get_weather_tool/0` returning a %Tool{}

  ## Type mapping

  - `:string` → `"string"`
  - `:integer` → `"integer"`
  - `:number` → `"number"`
  - `:boolean` → `"boolean"`
  - `{:enum, values}` → `"string"` + `"enum"`
  - `{:array, type}` → `"array"` + `"items"`
  - `{:object, fields}` → nested `"object"` with `"properties"`
  """

  alias AgentEx.Tool

  @type param_type ::
          :string
          | :integer
          | :number
          | :boolean
          | {:enum, [String.t()]}
          | {:array, param_type()}
          | {:object, [param_spec()]}

  @type param_spec ::
          {atom(), param_type(), String.t()}
          | {atom(), param_type(), String.t(), keyword()}

  @doc """
  Build a tool with auto-generated JSON Schema from param specs.

  ## Options
  - `:name` — tool name (required)
  - `:description` — tool description (required)
  - `:params` — list of param specs (required)
  - `:function` — tool function (required)
  - `:kind` — `:read` (default) or `:write`
  """
  @spec build(keyword()) :: Tool.t()
  def build(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    params = Keyword.fetch!(opts, :params)
    function = Keyword.fetch!(opts, :function)
    kind = Keyword.get(opts, :kind, :read)

    Tool.new(
      name: name,
      description: description,
      parameters: params_to_schema(params),
      function: function,
      kind: kind
    )
  end

  @doc "Convert a list of param specs to a JSON Schema object."
  @spec params_to_schema([param_spec()]) :: map()
  def params_to_schema(params) do
    {properties, required} =
      Enum.reduce(params, {%{}, []}, fn param, {props, req} ->
        {name, type, desc, opts} = normalize_param(param)
        key = Atom.to_string(name)
        prop = type_to_schema(type) |> Map.put("description", desc)

        props = Map.put(props, key, prop)

        req =
          if Keyword.get(opts, :optional, false),
            do: req,
            else: [key | req]

        {props, req}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.reverse(required)
    }
  end

  @doc "Convert a single type spec to its JSON Schema representation."
  @spec type_to_schema(param_type()) :: map()
  def type_to_schema(:string), do: %{"type" => "string"}
  def type_to_schema(:integer), do: %{"type" => "integer"}
  def type_to_schema(:number), do: %{"type" => "number"}
  def type_to_schema(:boolean), do: %{"type" => "boolean"}

  def type_to_schema({:enum, values}) do
    %{"type" => "string", "enum" => values}
  end

  def type_to_schema({:array, item_type}) do
    %{"type" => "array", "items" => type_to_schema(item_type)}
  end

  def type_to_schema({:object, fields}) do
    params_to_schema(fields)
  end

  @doc """
  Macro DSL for defining tools at compile time.

  Generates a `<name>_tool/0` function that returns a `%Tool{}`.
  The tool function must be defined separately as `<name>/1`.

  ## Example

      deftool :get_weather, "Get weather" do
        param :city, :string, "City name"
        param :units, :string, "C or F", optional: true
      end

      def get_weather(%{"city" => city} = _args) do
        {:ok, "Sunny in \#{city}"}
      end
  """
  defmacro deftool(name, description, opts \\ [], do: block) do
    kind = Keyword.get(opts, :kind, :read)
    tool_fn_name = :"#{name}_tool"

    quote do
      @__tool_params__ []

      unquote(block)

      @__tool_schema__ AgentEx.ToolBuilder.params_to_schema(
                         Enum.reverse(@__tool_params__)
                       )

      def unquote(tool_fn_name)() do
        mod = __MODULE__
        fun = unquote(name)

        AgentEx.Tool.new(
          name: unquote(Atom.to_string(name)),
          description: unquote(description),
          parameters: @__tool_schema__,
          function: fn args -> apply(mod, fun, [args]) end,
          kind: unquote(kind)
        )
      end
    end
  end

  @doc "Declare a parameter inside a `deftool` block."
  defmacro param(name, type, description, opts \\ []) do
    quote do
      @__tool_params__ [
        {unquote(name), unquote(type), unquote(description), unquote(opts)}
        | @__tool_params__
      ]
    end
  end

  # Normalize 3-tuple to 4-tuple
  defp normalize_param({name, type, desc}), do: {name, type, desc, []}
  defp normalize_param({name, type, desc, opts}), do: {name, type, desc, opts}
end
