defmodule AgentEx.Tools do
  @moduledoc """
  Local tool equivalents that work with any model via standard tool calling.

  Provides web search, URL fetching, code execution, and file operations
  without requiring provider-specific built-in tool support.
  """

  alias AgentEx.Tool

  @doc "Create a read-only tool with a single string parameter."
  def single_param_tool(name, description, param_name, param_desc, function) do
    Tool.new(
      name: name,
      description: description,
      kind: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{
          param_name => %{"type" => "string", "description" => param_desc}
        },
        "required" => [param_name]
      },
      function: function
    )
  end
end
