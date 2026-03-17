defmodule AgentEx.ToolAgent do
  @moduledoc """
  A GenServer that executes tools — maps to AutoGen's `ToolAgent`.

  In AutoGen, the ToolAgent is a separate agent in the runtime that receives
  `FunctionCall` messages and returns `FunctionExecutionResult` messages.

  In Elixir, this is naturally a GenServer that holds a registry of tools
  and executes them when called.

  ## AutoGen equivalent:
      tool_agent = ToolAgent(description="Tool agent", tools=[...])

  ## Elixir:
      {:ok, pid} = AgentEx.ToolAgent.start_link(tools: [tool1, tool2])
      result = AgentEx.ToolAgent.execute(pid, function_call)
  """

  use GenServer

  alias AgentEx.Message.{FunctionCall, FunctionResult}
  alias AgentEx.Tool

  # -- Public API --

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Execute a function call against the registered tools.

  Maps to AutoGen's: `caller.send_message(call, recipient=tool_agent_id)`
  """
  def execute(agent, %FunctionCall{} = call) do
    GenServer.call(agent, {:execute, call})
  end

  @doc "List all registered tools."
  def list_tools(agent) do
    GenServer.call(agent, :list_tools)
  end

  @doc "Get the tools map (%{name => Tool}). Useful for intervention handlers."
  def tools_map(agent) do
    GenServer.call(agent, :tools_map)
  end

  # -- GenServer callbacks --

  @doc "Get the agent ID."
  def agent_id(agent) do
    GenServer.call(agent, :agent_id)
  end

  @impl true
  def init(opts) do
    tools =
      opts
      |> Keyword.get(:tools, [])
      |> Map.new(fn %Tool{name: name} = tool -> {name, tool} end)

    agent_id = Keyword.get(opts, :agent_id)

    {:ok, %{tools: tools, agent_id: agent_id}}
  end

  @impl true
  def handle_call(
        {:execute, %FunctionCall{id: call_id, name: name, arguments: args_json}},
        _from,
        state
      ) do
    result = execute_call(state.tools, call_id, name, args_json)
    {:reply, result, state}
  end

  def handle_call(:list_tools, _from, state) do
    tools = state.tools |> Map.values()
    {:reply, tools, state}
  end

  def handle_call(:tools_map, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:agent_id, _from, state) do
    {:reply, state.agent_id, state}
  end

  # -- Private helpers --

  defp execute_call(tools, call_id, name, args_json) do
    with {:ok, tool} <- Map.fetch(tools, name),
         {:ok, args} <- decode_args(args_json),
         {:ok, value} <- Tool.execute(tool, args) do
      %FunctionResult{call_id: call_id, name: name, content: to_string(value), is_error: false}
    else
      :error ->
        %FunctionResult{
          call_id: call_id,
          name: name,
          content: "Error: unknown tool '#{name}'",
          is_error: true
        }

      {:error, :invalid_json} ->
        %FunctionResult{
          call_id: call_id,
          name: name,
          content: "Error: invalid JSON arguments",
          is_error: true
        }

      {:error, reason} ->
        %FunctionResult{
          call_id: call_id,
          name: name,
          content: "Error: #{inspect(reason)}",
          is_error: true
        }
    end
  end

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, args} -> {:ok, args}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
