defmodule AgentEx.MCP.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias AgentEx.MCP.ToolAdapter
  alias AgentEx.Tool

  describe "to_agent_ex_tool/2" do
    test "converts MCP tool to AgentEx tool" do
      mcp_tool = %{
        "name" => "list_repos",
        "description" => "List GitHub repositories for an org",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "org" => %{"type" => "string", "description" => "Organization name"}
          },
          "required" => ["org"]
        }
      }

      # Use self() as a mock MCP pid (we won't actually call it)
      tool = ToolAdapter.to_agent_ex_tool(mcp_tool, self())

      assert %Tool{} = tool
      assert tool.name == "list_repos"
      assert tool.description == "List GitHub repositories for an org"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["properties"]["org"]["type"] == "string"
      assert tool.kind == :read
    end

    test "infers write kind for mutation tools" do
      mcp_tool = %{
        "name" => "create_issue",
        "description" => "Create a new GitHub issue",
        "inputSchema" => %{}
      }

      tool = ToolAdapter.to_agent_ex_tool(mcp_tool, self())
      assert tool.kind == :write
    end

    test "infers write kind for delete tools" do
      mcp_tool = %{
        "name" => "delete_branch",
        "description" => "Delete a Git branch",
        "inputSchema" => %{}
      }

      tool = ToolAdapter.to_agent_ex_tool(mcp_tool, self())
      assert tool.kind == :write
    end

    test "handles missing inputSchema" do
      mcp_tool = %{
        "name" => "simple_tool",
        "description" => "A simple tool"
      }

      tool = ToolAdapter.to_agent_ex_tool(mcp_tool, self())
      assert tool.parameters == %{}
    end
  end

  describe "to_mcp_tool/1" do
    test "converts AgentEx tool to MCP format" do
      tool =
        Tool.new(
          name: "get_weather",
          description: "Get weather",
          parameters: %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          },
          function: fn _ -> {:ok, "sunny"} end
        )

      mcp = ToolAdapter.to_mcp_tool(tool)

      assert mcp == %{
               "name" => "get_weather",
               "description" => "Get weather",
               "inputSchema" => %{
                 "type" => "object",
                 "properties" => %{"city" => %{"type" => "string"}},
                 "required" => ["city"]
               }
             }
    end

    test "handles nil parameters" do
      tool = Tool.new(name: "noop", description: "No-op", function: fn _ -> {:ok, ""} end)
      mcp = ToolAdapter.to_mcp_tool(tool)
      assert mcp["inputSchema"] == %{}
    end
  end

  describe "list_tools/1 integration" do
    # Uses the MockClient from client_test.exs pattern
    defmodule FakeMCPServer do
      use GenServer

      def start_link(tools) do
        GenServer.start_link(__MODULE__, tools)
      end

      @impl true
      def init(tools), do: {:ok, tools}

      @impl true
      def handle_call(:list_tools, _from, tools) do
        {:reply, {:ok, tools}, tools}
      end

      def handle_call({:call_tool, name, args}, _from, tools) do
        {:reply, {:ok, "Executed #{name} with #{inspect(args)}"}, tools}
      end
    end

    test "discovers tools from MCP server" do
      mcp_tools = [
        %{
          "name" => "search",
          "description" => "Search documents",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        },
        %{
          "name" => "update_doc",
          "description" => "Update a document",
          "inputSchema" => %{}
        }
      ]

      {:ok, fake_mcp} = FakeMCPServer.start_link(mcp_tools)
      tools = ToolAdapter.list_tools(fake_mcp)

      assert length(tools) == 2
      names = Enum.map(tools, & &1.name)
      assert "search" in names
      assert "update_doc" in names

      # search is read, update is write
      search = Enum.find(tools, &(&1.name == "search"))
      update = Enum.find(tools, &(&1.name == "update_doc"))
      assert search.kind == :read
      assert update.kind == :write
    end

    test "tool function calls MCP server" do
      mcp_tools = [
        %{"name" => "echo", "description" => "Echo args", "inputSchema" => %{}}
      ]

      {:ok, fake_mcp} = FakeMCPServer.start_link(mcp_tools)
      [tool] = ToolAdapter.list_tools(fake_mcp)

      assert {:ok, result} = Tool.execute(tool, %{"msg" => "hello"})
      assert result =~ "Executed echo"
    end
  end
end
