defmodule AgentEx.PluginRegistry do
  @moduledoc """
  Lifecycle manager for ToolPlugins.

  A GenServer that manages plugin attach/detach and delegates tool storage
  to a `Workbench`. Stateful plugins get their child_specs started under
  `AgentEx.PluginSupervisor`.

  ## Example

      {:ok, wb} = Workbench.start_link()
      {:ok, reg} = PluginRegistry.start_link(workbench: wb)
      :ok = PluginRegistry.attach(reg, MyPlugin, %{"api_key" => "sk-..."})
      [%PluginInfo{}] = PluginRegistry.list_attached(reg)
  """

  use GenServer

  alias AgentEx.{ToolPlugin, Workbench}

  require Logger

  defmodule PluginInfo do
    @moduledoc "Metadata for an attached plugin."
    defstruct [:module, :name, :version, :description, :tool_names, :child_pid]

    @type t :: %__MODULE__{
            module: module(),
            name: String.t(),
            version: String.t(),
            description: String.t(),
            tool_names: [String.t()],
            child_pid: pid() | nil
          }
  end

  defstruct plugins: %{}, workbench: nil

  # -- Public API --

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Attach a plugin with the given config."
  @spec attach(GenServer.server(), module(), map()) :: :ok | {:error, term()}
  def attach(registry, module, config \\ %{}) do
    GenServer.call(registry, {:attach, module, config}, 30_000)
  end

  @doc "Detach a plugin by name, removing its tools."
  @spec detach(GenServer.server(), String.t()) :: :ok | {:error, :not_attached}
  def detach(registry, plugin_name) when is_binary(plugin_name) do
    GenServer.call(registry, {:detach, plugin_name})
  end

  @doc "List all attached plugins."
  @spec list_attached(GenServer.server()) :: [PluginInfo.t()]
  def list_attached(registry) do
    GenServer.call(registry, :list_attached)
  end

  @doc "Get info for a specific plugin."
  @spec get_plugin(GenServer.server(), String.t()) :: {:ok, PluginInfo.t()} | :not_found
  def get_plugin(registry, plugin_name) when is_binary(plugin_name) do
    GenServer.call(registry, {:get_plugin, plugin_name})
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    workbench = Keyword.fetch!(opts, :workbench)
    {:ok, %__MODULE__{workbench: workbench}}
  end

  @impl true
  def handle_call({:attach, module, config}, _from, state) do
    manifest = module.manifest()
    plugin_name = manifest.name

    if Map.has_key?(state.plugins, plugin_name) do
      {:reply, {:error, :already_attached}, state}
    else
      case ToolPlugin.validate_config(module, config) do
        {:error, errors} ->
          {:reply, {:error, {:config_invalid, errors}}, state}

        :ok ->
          do_attach(module, manifest, config, state)
      end
    end
  end

  def handle_call({:detach, plugin_name}, _from, state) do
    case Map.fetch(state.plugins, plugin_name) do
      {:ok, info} ->
        # Remove tools from workbench
        Workbench.remove_tools(state.workbench, info.tool_names)

        # Stop child process if stateful
        if info.child_pid do
          DynamicSupervisor.terminate_child(AgentEx.PluginSupervisor, info.child_pid)
        end

        # Run cleanup if defined
        if function_exported?(info.module, :cleanup, 1) do
          info.module.cleanup(info.child_pid)
        end

        Logger.info("PluginRegistry: detached plugin '#{plugin_name}'")
        {:reply, :ok, %{state | plugins: Map.delete(state.plugins, plugin_name)}}

      :error ->
        {:reply, {:error, :not_attached}, state}
    end
  end

  def handle_call(:list_attached, _from, state) do
    {:reply, Map.values(state.plugins), state}
  end

  def handle_call({:get_plugin, plugin_name}, _from, state) do
    case Map.fetch(state.plugins, plugin_name) do
      {:ok, info} -> {:reply, {:ok, info}, state}
      :error -> {:reply, :not_found, state}
    end
  end

  # -- Private --

  defp do_attach(module, manifest, config, state) do
    plugin_name = manifest.name

    case module.init(config) do
      {:ok, tools} ->
        prefixed = ToolPlugin.prefix_tools(plugin_name, tools)
        Workbench.add_tools(state.workbench, prefixed)
        tool_names = Enum.map(prefixed, & &1.name)

        info = %PluginInfo{
          module: module,
          name: plugin_name,
          version: manifest.version,
          description: manifest.description,
          tool_names: tool_names,
          child_pid: nil
        }

        Logger.info("PluginRegistry: attached '#{plugin_name}' with #{length(tools)} tools")
        {:reply, :ok, %{state | plugins: Map.put(state.plugins, plugin_name, info)}}

      {:stateful, tools, child_spec} ->
        case DynamicSupervisor.start_child(AgentEx.PluginSupervisor, child_spec) do
          {:ok, child_pid} ->
            prefixed = ToolPlugin.prefix_tools(plugin_name, tools)
            Workbench.add_tools(state.workbench, prefixed)
            tool_names = Enum.map(prefixed, & &1.name)

            info = %PluginInfo{
              module: module,
              name: plugin_name,
              version: manifest.version,
              description: manifest.description,
              tool_names: tool_names,
              child_pid: child_pid
            }

            Logger.info(
              "PluginRegistry: attached stateful '#{plugin_name}' with #{length(tools)} tools"
            )

            {:reply, :ok, %{state | plugins: Map.put(state.plugins, plugin_name, info)}}

          {:error, reason} ->
            {:reply, {:error, {:child_start_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:init_failed, reason}}, state}
    end
  end
end
