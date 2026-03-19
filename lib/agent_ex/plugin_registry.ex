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
  @spec detach(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def detach(registry, plugin_name) when is_binary(plugin_name) do
    GenServer.call(registry, {:detach, plugin_name})
  end

  @doc "List all attached plugins."
  @spec list_attached(GenServer.server()) :: [PluginInfo.t()]
  def list_attached(registry) do
    GenServer.call(registry, :list_attached)
  end

  @doc "Get info for a specific plugin."
  @spec get_plugin(GenServer.server(), String.t()) :: {:ok, PluginInfo.t()} | {:error, :not_found}
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
    with {:ok, manifest} <- safe_manifest(module),
         :ok <- check_not_attached(state, manifest.name),
         :ok <- validate_plugin_config(module, config) do
      do_attach(module, manifest, config, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach, plugin_name}, _from, state) do
    case Map.fetch(state.plugins, plugin_name) do
      {:ok, info} ->
        Workbench.remove_tools(state.workbench, info.tool_names)
        run_plugin_cleanup(info, plugin_name)

        Logger.info("PluginRegistry: detached plugin '#{plugin_name}'")
        {:reply, :ok, %{state | plugins: Map.delete(state.plugins, plugin_name)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_attached, _from, state) do
    {:reply, Map.values(state.plugins), state}
  end

  def handle_call({:get_plugin, plugin_name}, _from, state) do
    case Map.fetch(state.plugins, plugin_name) do
      {:ok, info} -> {:reply, {:ok, info}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  # -- Private --

  defp safe_manifest(module) do
    case safe_callback(module, :manifest, []) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, reason} -> {:error, {:callback_failed, module, :manifest, reason}}
    end
  end

  defp validate_plugin_config(module, config) do
    case ToolPlugin.validate_config(module, config) do
      :ok -> :ok
      {:error, errors} -> {:error, {:config_invalid, errors}}
    end
  end

  defp check_not_attached(state, plugin_name) do
    if Map.has_key?(state.plugins, plugin_name),
      do: {:error, :already_attached},
      else: :ok
  end

  defp run_plugin_cleanup(info, plugin_name) do
    if function_exported?(info.module, :cleanup, 1) do
      case safe_callback(info.module, :cleanup, [info.child_pid]) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "PluginRegistry: cleanup failed for '#{plugin_name}': #{inspect(reason)}"
          )
      end
    end

    if info.child_pid do
      DynamicSupervisor.terminate_child(AgentEx.PluginSupervisor, info.child_pid)
    end
  end

  defp safe_callback(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    e -> {:error, {Exception.message(e), __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp do_attach(module, manifest, config, state) do
    case safe_callback(module, :init, [config]) do
      {:ok, result} -> do_attach_result(result, module, manifest, state)
      {:error, reason} -> {:reply, {:error, {:callback_failed, module, :init, reason}}, state}
    end
  end

  defp do_attach_result(result, module, manifest, state) do
    plugin_name = manifest.name

    case result do
      {:ok, tools} ->
        prefixed = ToolPlugin.prefix_tools(plugin_name, tools)
        {:ok, %{inserted: inserted}} = Workbench.add_tools(state.workbench, prefixed)

        info = %PluginInfo{
          module: module,
          name: plugin_name,
          version: manifest.version,
          description: manifest.description,
          tool_names: inserted,
          child_pid: nil
        }

        Logger.info("PluginRegistry: attached '#{plugin_name}' with #{length(inserted)} tools")
        {:reply, :ok, %{state | plugins: Map.put(state.plugins, plugin_name, info)}}

      {:stateful, tools, child_spec} ->
        case DynamicSupervisor.start_child(AgentEx.PluginSupervisor, child_spec) do
          {:ok, child_pid} ->
            prefixed = ToolPlugin.prefix_tools(plugin_name, tools)
            {:ok, %{inserted: inserted}} = Workbench.add_tools(state.workbench, prefixed)

            info = %PluginInfo{
              module: module,
              name: plugin_name,
              version: manifest.version,
              description: manifest.description,
              tool_names: inserted,
              child_pid: child_pid
            }

            Logger.info(
              "PluginRegistry: attached stateful '#{plugin_name}' with #{length(inserted)} tools"
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
