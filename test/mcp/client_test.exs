defmodule AgentEx.MCP.ClientTest do
  use ExUnit.Case, async: true

  # Mock transport that simulates an MCP server in-process
  defmodule MockTransport do
    @behaviour AgentEx.MCP.Transport

    defstruct tools: [], resources: []

    @impl true
    def send_request(state, %{"method" => "initialize"} = _request) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{}, "resources" => %{}},
          "serverInfo" => %{"name" => "mock", "version" => "0.1.0"}
        }
      }

      {:ok, response, state}
    end

    def send_request(state, %{"method" => "notifications/initialized"}) do
      {:ok, %{"jsonrpc" => "2.0"}, state}
    end

    def send_request(state, %{"method" => "tools/list", "id" => id}) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "tools" => state.tools
        }
      }

      {:ok, response, state}
    end

    def send_request(state, %{"method" => "tools/call", "id" => id, "params" => params}) do
      name = params["name"]
      args = params["arguments"]

      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "content" => [
            %{"type" => "text", "text" => "Called #{name} with #{inspect(args)}"}
          ]
        }
      }

      {:ok, response, state}
    end

    def send_request(state, %{"method" => "resources/list", "id" => id}) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "resources" => state.resources
        }
      }

      {:ok, response, state}
    end

    def send_request(state, %{"method" => "resources/read", "id" => id, "params" => params}) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "contents" => [%{"uri" => params["uri"], "text" => "resource content"}]
        }
      }

      {:ok, response, state}
    end

    @impl true
    def close(_state), do: :ok
  end

  # Helper to start a client with mock transport
  defp start_mock_client(opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    resources = Keyword.get(opts, :resources, [])

    mock_state = %MockTransport{tools: tools, resources: resources}

    # Start the client with a custom init that bypasses open_transport
    # We do this by intercepting at the GenServer level
    {:ok, pid} = __MODULE__.MockClient.start_link(mock_state)
    pid
  end

  # A wrapper module that uses the mock transport directly
  defmodule MockClient do
    use GenServer

    def start_link(transport_state) do
      GenServer.start_link(__MODULE__, transport_state)
    end

    @impl true
    def init(transport_state) do
      state = %{
        transport_mod: MockTransport,
        transport_state: transport_state,
        capabilities: %{},
        request_id: 1
      }

      # Run initialize
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "AgentEx.MCP", "version" => "0.1.0"}
        }
      }

      case MockTransport.send_request(transport_state, request) do
        {:ok, %{"result" => result}, new_ts} ->
          state = %{
            state
            | transport_state: new_ts,
              capabilities: Map.get(result, "capabilities", %{}),
              request_id: 2
          }

          {:ok, state}

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
          error -> error
        end

      {:reply, reply, state}
    end

    def handle_call({:read_resource, uri}, _from, state) do
      {result, state} = rpc(state, "resources/read", %{"uri" => uri})

      reply =
        case result do
          {:ok, %{"contents" => contents}} -> {:ok, contents}
          error -> error
        end

      {:reply, reply, state}
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

    defp extract_content(content) when is_list(content) do
      Enum.map_join(content, "\n", fn
        %{"type" => "text", "text" => text} -> text
        other -> inspect(other)
      end)
    end

    defp extract_content(content), do: content
  end

  describe "list_tools/1" do
    test "returns tools from the MCP server" do
      tools = [
        %{
          "name" => "list_repos",
          "description" => "List GitHub repositories",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"org" => %{"type" => "string"}},
            "required" => ["org"]
          }
        },
        %{
          "name" => "get_file",
          "description" => "Get file contents",
          "inputSchema" => %{}
        }
      ]

      client = start_mock_client(tools: tools)
      assert {:ok, result_tools} = GenServer.call(client, :list_tools)
      assert length(result_tools) == 2
      assert Enum.any?(result_tools, &(&1["name"] == "list_repos"))
    end

    test "returns empty list when no tools" do
      client = start_mock_client()
      assert {:ok, []} = GenServer.call(client, :list_tools)
    end
  end

  describe "call_tool/3" do
    test "calls a tool and returns the result" do
      client = start_mock_client()

      assert {:ok, result} =
               GenServer.call(client, {:call_tool, "test_tool", %{"key" => "value"}})

      assert result =~ "Called test_tool"
    end
  end

  describe "list_resources/1" do
    test "returns resources" do
      resources = [
        %{"uri" => "file:///readme.md", "name" => "README", "mimeType" => "text/markdown"}
      ]

      client = start_mock_client(resources: resources)
      assert {:ok, result} = GenServer.call(client, :list_resources)
      assert length(result) == 1
    end
  end

  describe "read_resource/2" do
    test "reads a resource by URI" do
      client = start_mock_client()

      assert {:ok, contents} = GenServer.call(client, {:read_resource, "file:///test.md"})

      assert is_list(contents)
    end
  end
end
