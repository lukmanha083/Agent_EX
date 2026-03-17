defmodule AgentEx.MCP.Client do
  @moduledoc """
  GenServer managing a connection to an MCP (Model Context Protocol) server.

  Maps to AutoGen's `mcp_server_tools` integration. Handles JSON-RPC 2.0
  communication for tool discovery and invocation.

  ## Example

      {:ok, mcp} = MCP.Client.start_link(
        transport: {:stdio, "npx -y @anthropic-ai/mcp-server-github"}
      )

      tools = MCP.Client.list_tools(mcp)
      result = MCP.Client.call_tool(mcp, "list_repos", %{"org" => "anthropics"})
  """

  use GenServer

  alias AgentEx.MCP.Transport

  require Logger

  defstruct [:transport_mod, :transport_state, :capabilities, :request_id]

  # -- Public API --

  @doc """
  Start an MCP client.

  ## Options
  - `:transport` — `{:stdio, command}` or `{:http, url}`
  - `:name` — optional GenServer name
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "List available tools from the MCP server."
  @spec list_tools(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(server) do
    GenServer.call(server, :list_tools, 30_000)
  end

  @doc "Call a tool on the MCP server."
  @spec call_tool(GenServer.server(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(server, name, args \\ %{}) do
    GenServer.call(server, {:call_tool, name, args}, 30_000)
  end

  @doc "List available resources from the MCP server."
  @spec list_resources(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(server) do
    GenServer.call(server, :list_resources, 30_000)
  end

  @doc "Read a resource by URI."
  @spec read_resource(GenServer.server(), String.t()) :: {:ok, term()} | {:error, term()}
  def read_resource(server, uri) do
    GenServer.call(server, {:read_resource, uri}, 30_000)
  end

  @doc "Close the MCP connection."
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.stop(server, :normal)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    transport_spec = Keyword.fetch!(opts, :transport)

    case open_transport(transport_spec) do
      {:ok, mod, transport_state} ->
        state = %__MODULE__{
          transport_mod: mod,
          transport_state: transport_state,
          request_id: 1
        }

        case initialize(state) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {result, state} = rpc(state, "tools/list", %{})

    reply =
      case result do
        {:ok, %{"tools" => tools}} -> {:ok, tools}
        {:ok, other} -> {:ok, Map.get(other, "tools", [])}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:call_tool, name, args}, _from, state) do
    {result, state} = rpc(state, "tools/call", %{"name" => name, "arguments" => args})

    reply =
      case result do
        {:ok, %{"content" => content}} -> {:ok, extract_content(content)}
        {:ok, response} -> {:ok, response}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call(:list_resources, _from, state) do
    {result, state} = rpc(state, "resources/list", %{})

    reply =
      case result do
        {:ok, %{"resources" => resources}} -> {:ok, resources}
        {:ok, other} -> {:ok, Map.get(other, "resources", [])}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:read_resource, uri}, _from, state) do
    {result, state} = rpc(state, "resources/read", %{"uri" => uri})

    reply =
      case result do
        {:ok, %{"contents" => contents}} -> {:ok, contents}
        {:ok, response} -> {:ok, response}
        error -> error
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{transport_mod: mod, transport_state: ts}) do
    mod.close(ts)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- JSON-RPC helpers --

  defp initialize(state) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => state.request_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "AgentEx.MCP",
          "version" => "0.1.0"
        }
      }
    }

    case state.transport_mod.send_request(state.transport_state, request) do
      {:ok, %{"result" => result}, new_ts} ->
        state = %{
          state
          | transport_state: new_ts,
            capabilities: Map.get(result, "capabilities", %{}),
            request_id: state.request_id + 1
        }

        # Send initialized notification
        notification = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        }

        case state.transport_mod.send_request(state.transport_state, notification) do
          {:ok, _, new_ts} -> {:ok, %{state | transport_state: new_ts}}
          # Notifications may not get a response in some transports
          {:error, :timeout} -> {:ok, state}
          {:error, _} -> {:ok, state}
        end

      {:ok, %{"error" => error}, _} ->
        {:error, {:mcp_error, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rpc(state, method, params) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => state.request_id,
      "method" => method,
      "params" => params
    }

    state = %{state | request_id: state.request_id + 1}

    case state.transport_mod.send_request(state.transport_state, request) do
      {:ok, %{"result" => result}, new_ts} ->
        {{:ok, result}, %{state | transport_state: new_ts}}

      {:ok, %{"error" => error}, new_ts} ->
        {{:error, {:mcp_error, error}}, %{state | transport_state: new_ts}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp open_transport({:stdio, command}) do
    case Transport.Stdio.open(command) do
      {:ok, ts} -> {:ok, Transport.Stdio, ts}
      error -> error
    end
  end

  defp open_transport({:http, url}) do
    case Transport.HTTP.open(url) do
      {:ok, ts} -> {:ok, Transport.HTTP, ts}
      error -> error
    end
  end

  defp extract_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp extract_content(content), do: content
end
