defmodule AgentEx.MCP.ToolAdapter do
  @moduledoc """
  Convert MCP tools to AgentEx tools and vice versa.

  Bridges the MCP `tools/list` response into `%AgentEx.Tool{}` structs that
  can be used with ToolAgent, Workbench, or any other AgentEx component.

  ## Example

      {:ok, mcp} = MCP.Client.start_link(transport: {:stdio, "mcp-server"})
      tools = MCP.ToolAdapter.list_tools(mcp)
      {:ok, agent} = ToolAgent.start_link(tools: tools)
  """

  alias AgentEx.MCP.Client
  alias AgentEx.Tool

  @doc """
  Discover tools from an MCP server and convert them to AgentEx tools.

  Each tool's function is a closure that calls `MCP.Client.call_tool/3`.
  """
  @spec list_tools(GenServer.server()) :: [Tool.t()]
  def list_tools(mcp) do
    case Client.list_tools(mcp) do
      {:ok, tools} -> Enum.map(tools, &to_agent_ex_tool(&1, mcp))
      {:error, _} -> []
    end
  end

  @doc """
  Convert a single MCP tool definition to an AgentEx Tool.

  The returned tool's function calls the MCP server when executed.
  """
  @spec to_agent_ex_tool(map(), GenServer.server()) :: Tool.t()
  def to_agent_ex_tool(mcp_tool, mcp_pid) do
    name = mcp_tool["name"]
    description = mcp_tool["description"]
    input_schema = mcp_tool["inputSchema"] || %{}

    Tool.new(
      name: name,
      description: description,
      parameters: input_schema,
      kind: infer_kind(name, description),
      function: fn args ->
        Client.call_tool(mcp_pid, name, args)
      end
    )
  end

  @doc """
  Convert an AgentEx Tool to MCP tool format (for serving as an MCP server).
  """
  @spec to_mcp_tool(Tool.t()) :: map()
  def to_mcp_tool(%Tool{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.parameters || %{}
    }
  end

  # Infer tool kind from name/description heuristics.
  # Write operations typically include these verbs.
  @write_indicators ~w(create delete update write remove modify set put post patch)

  defp infer_kind(name, description) do
    text = String.downcase("#{name} #{description}")

    if Enum.any?(@write_indicators, &String.contains?(text, &1)) do
      :write
    else
      :read
    end
  end
end
