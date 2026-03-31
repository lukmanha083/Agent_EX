defmodule AgentEx.ToolPlugin do
  @moduledoc """
  Behaviour for reusable, configurable tool bundles.

  A plugin declares a manifest (name, version, config schema) and an `init/1`
  that returns tools. Simple plugins stay simple — stateful ones can declare
  a child_spec for supervised processes.

  Tool names are prefixed with the plugin name (e.g., `"filesystem_read_file"`)
  to avoid collisions across plugins.

  ## Example

      defmodule MyPlugin do
        @behaviour AgentEx.ToolPlugin

        @impl true
        def manifest do
          %{
            name: "my_plugin",
            version: "1.0.0",
            description: "Does useful things",
            config_schema: [{:api_key, :string, "API key"}]
          }
        end

        @impl true
        def init(config) do
          {:ok, [my_tool(config)]}
        end
      end
  """

  @type manifest :: %{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          config_schema: [AgentEx.ToolBuilder.param_spec()]
        }

  @type init_result ::
          {:ok, [AgentEx.Tool.t()]}
          | {:stateful, [AgentEx.Tool.t()], Supervisor.child_spec()}
          | {:error, term()}

  @callback manifest() :: manifest()
  @callback init(config :: map()) :: init_result()
  @callback cleanup(state :: term()) :: :ok
  @optional_callbacks [cleanup: 1]

  @doc "Validate config against the plugin's config_schema."
  @spec validate_config(module(), map()) :: :ok | {:error, [String.t()]}
  def validate_config(plugin_module, config) when is_map(config) do
    schema = plugin_module.manifest().config_schema

    errors =
      Enum.flat_map(schema, fn param ->
        {name, type, _desc, opts} = normalize_param(param)
        key = Atom.to_string(name)
        optional = Keyword.get(opts, :optional, false)
        value = Map.get(config, key)

        cond do
          value == nil and not optional ->
            ["missing required config: #{name}"]

          value != nil and not valid_type?(value, type) ->
            ["invalid type for config: #{name}, expected #{inspect(type)}"]

          true ->
            []
        end
      end)

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :float), do: is_float(value)

  defp valid_type?(value, {:array, inner}),
    do: is_list(value) and Enum.all?(value, &valid_type?(&1, inner))

  defp valid_type?(_value, _type), do: true

  @doc "Prefix tool names with the plugin name (underscore separator for API compatibility)."
  @spec prefix_tools(String.t(), [AgentEx.Tool.t()]) :: [AgentEx.Tool.t()]
  def prefix_tools(plugin_name, tools) do
    Enum.map(tools, fn tool ->
      %{tool | name: "#{plugin_name}_#{tool.name}"}
    end)
  end

  defp normalize_param({name, type, desc}), do: {name, type, desc, []}
  defp normalize_param({name, type, desc, opts}), do: {name, type, desc, opts}
end
