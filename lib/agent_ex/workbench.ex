defmodule AgentEx.Workbench do
  @moduledoc """
  Dynamic tool collection — maps to AutoGen's `Workbench` protocol.

  A GenServer that manages a mutable registry of tools with version tracking.
  Tools can be added, removed, and updated at runtime. The version counter
  lets callers avoid resending unchanged tool lists to the LLM.

  ## Example

      {:ok, wb} = Workbench.start_link()
      :ok = Workbench.add_tool(wb, my_tool)
      tools = Workbench.list_tools(wb)
      result = Workbench.call_tool(wb, "my_tool", %{"arg" => "val"})

  ## Version tracking

      v1 = Workbench.version(wb)
      Workbench.add_tool(wb, new_tool)
      {:changed, tools, v2} = Workbench.tools_if_changed(wb, v1)
  """

  use GenServer

  alias AgentEx.Message.FunctionResult
  alias AgentEx.{Tool, ToolOverride}

  defstruct tools: %{}, version: 0, agent_id: nil

  # -- Public API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add a tool to the workbench."
  @spec add_tool(GenServer.server(), Tool.t()) :: :ok | {:error, :already_exists}
  def add_tool(wb, %Tool{} = tool) do
    GenServer.call(wb, {:add_tool, tool})
  end

  @doc "Remove a tool by name."
  @spec remove_tool(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def remove_tool(wb, name) when is_binary(name) do
    GenServer.call(wb, {:remove_tool, name})
  end

  @doc "Update a tool's fields by name."
  @spec update_tool(GenServer.server(), String.t(), keyword()) :: :ok | {:error, :not_found}
  def update_tool(wb, name, changes) when is_binary(name) and is_list(changes) do
    GenServer.call(wb, {:update_tool, name, changes})
  end

  @doc "List all tools."
  @spec list_tools(GenServer.server()) :: [Tool.t()]
  def list_tools(wb) do
    GenServer.call(wb, :list_tools)
  end

  @doc "Get a tool by name."
  @spec get_tool(GenServer.server(), String.t()) :: {:ok, Tool.t()} | :not_found
  def get_tool(wb, name) when is_binary(name) do
    GenServer.call(wb, {:get_tool, name})
  end

  @doc "Execute a tool by name with arguments."
  @spec call_tool(GenServer.server(), String.t(), map()) :: FunctionResult.t()
  def call_tool(wb, name, args) when is_binary(name) and is_map(args) do
    GenServer.call(wb, {:call_tool, name, args})
  end

  @doc "Get the current version number."
  @spec version(GenServer.server()) :: non_neg_integer()
  def version(wb) do
    GenServer.call(wb, :version)
  end

  @doc "Get tools only if changed since the given version."
  @spec tools_if_changed(GenServer.server(), non_neg_integer()) ::
          {:changed, [Tool.t()], non_neg_integer()} | :unchanged
  def tools_if_changed(wb, since_version) do
    GenServer.call(wb, {:tools_if_changed, since_version})
  end

  @doc "Add multiple tools at once. Skips tools that already exist."
  @spec add_tools(GenServer.server(), [Tool.t()]) :: :ok
  def add_tools(wb, tools) when is_list(tools) do
    GenServer.call(wb, {:add_tools, tools})
  end

  @doc "Remove multiple tools by name. Skips tools that don't exist."
  @spec remove_tools(GenServer.server(), [String.t()]) :: :ok
  def remove_tools(wb, names) when is_list(names) do
    GenServer.call(wb, {:remove_tools, names})
  end

  @doc "Add a tool with overrides applied via ToolOverride."
  @spec add_override(GenServer.server(), Tool.t(), keyword()) :: :ok | {:error, :already_exists}
  def add_override(wb, %Tool{} = tool, overrides) do
    wrapped = ToolOverride.wrap(tool, overrides)
    add_tool(wb, wrapped)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    tools =
      opts
      |> Keyword.get(:tools, [])
      |> Map.new(fn %Tool{name: name} = tool -> {name, tool} end)

    agent_id = Keyword.get(opts, :agent_id)

    {:ok, %__MODULE__{tools: tools, version: 0, agent_id: agent_id}}
  end

  @impl true
  def handle_call({:add_tool, %Tool{name: name} = tool}, _from, state) do
    if Map.has_key?(state.tools, name) do
      {:reply, {:error, :already_exists}, state}
    else
      new_state = %{state | tools: Map.put(state.tools, name, tool), version: state.version + 1}
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:remove_tool, name}, _from, state) do
    if Map.has_key?(state.tools, name) do
      new_state = %{state | tools: Map.delete(state.tools, name), version: state.version + 1}
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update_tool, name, changes}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} ->
        updated = struct(tool, changes)

        new_state = %{
          state
          | tools: Map.put(state.tools, name, updated),
            version: state.version + 1
        }

        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, Map.values(state.tools), state}
  end

  def handle_call({:get_tool, name}, _from, state) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} -> {:reply, {:ok, tool}, state}
      :error -> {:reply, :not_found, state}
    end
  end

  def handle_call({:call_tool, name, args}, _from, state) do
    result =
      case Map.fetch(state.tools, name) do
        {:ok, tool} ->
          case Tool.execute(tool, args) do
            {:ok, value} ->
              %FunctionResult{
                call_id: "wb_#{name}_#{System.unique_integer([:positive])}",
                name: name,
                content: to_string(value)
              }

            {:error, reason} ->
              %FunctionResult{
                call_id: "wb_#{name}_#{System.unique_integer([:positive])}",
                name: name,
                content: "Error: #{inspect(reason)}",
                is_error: true
              }
          end

        :error ->
          %FunctionResult{
            call_id: "wb_#{name}_#{System.unique_integer([:positive])}",
            name: name,
            content: "Error: unknown tool '#{name}'",
            is_error: true
          }
      end

    {:reply, result, state}
  end

  def handle_call({:add_tools, tools}, _from, state) do
    new_tools =
      Enum.reduce(tools, state.tools, fn %Tool{name: name} = tool, acc ->
        if Map.has_key?(acc, name), do: acc, else: Map.put(acc, name, tool)
      end)

    new_state = %{state | tools: new_tools, version: state.version + 1}
    {:reply, :ok, new_state}
  end

  def handle_call({:remove_tools, names}, _from, state) do
    new_tools = Map.drop(state.tools, names)
    new_state = %{state | tools: new_tools, version: state.version + 1}
    {:reply, :ok, new_state}
  end

  def handle_call(:version, _from, state) do
    {:reply, state.version, state}
  end

  def handle_call({:tools_if_changed, since_version}, _from, state) do
    if state.version > since_version do
      {:reply, {:changed, Map.values(state.tools), state.version}, state}
    else
      {:reply, :unchanged, state}
    end
  end
end
