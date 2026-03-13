defmodule AgentEx.Handoff do
  @moduledoc """
  HandoffMessage and transfer tools — maps to AutoGen's Swarm handoff pattern.

  In AutoGen, each agent declares who it can hand off to. The framework generates
  `transfer_to_<name>()` tools that the LLM can call to route conversation to
  another agent. The LLM doesn't need special handoff logic — it just sees tools
  and decides which one to call. The framework does the routing.

  ## AutoGen equivalent (Python):

      planner = AssistantAgent(
          name="planner",
          handoffs=["analyst", "writer"],
          ...
      )

  ## AgentEx:

      # Generate transfer tools for handoff targets
      Handoff.transfer_tools(["analyst", "writer"])
      #=> [%Tool{name: "transfer_to_analyst", ...}, %Tool{name: "transfer_to_writer", ...}]

      # Detect handoffs in LLM tool calls
      Handoff.detect(tool_calls)
      #=> {:handoff, "analyst", %FunctionCall{...}}
  """

  alias AgentEx.Message.FunctionCall
  alias AgentEx.Tool

  @transfer_prefix "transfer_to_"

  defmodule HandoffMessage do
    @moduledoc """
    A message that transfers conversation to another agent.

    Maps to AutoGen's `HandoffMessage`:
    - `target` — name of the agent to hand off to
    - `content` — human-readable reason for the handoff
    - `source` — who initiated the handoff
    - `context` — optional conversation history to pass along
    """
    @enforce_keys [:target]
    defstruct [:target, :content, :source, context: []]

    @type t :: %__MODULE__{
            target: String.t(),
            content: String.t() | nil,
            source: String.t() | nil,
            context: [AgentEx.Message.t()]
          }
  end

  @doc """
  Generate a transfer tool for a target agent.

  The tool is `:write` kind (handoffs are actions that change the world).
  When the LLM calls this tool, the Swarm orchestrator detects the handoff
  and routes the conversation to the target agent.

  ## Example

      tool = Handoff.transfer_tool("analyst")
      tool.name  #=> "transfer_to_analyst"
      tool.kind  #=> :write
  """
  @spec transfer_tool(String.t()) :: Tool.t()
  def transfer_tool(target_name) when is_binary(target_name) do
    Tool.new(
      name: @transfer_prefix <> target_name,
      description:
        "Transfer conversation to #{target_name}. " <>
          "Call this when the current task should be handled by #{target_name}.",
      kind: :write,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "reason" => %{
            "type" => "string",
            "description" => "Brief reason for the transfer"
          }
        },
        "required" => []
      },
      function: fn args ->
        reason = Map.get(args, "reason", "")
        {:ok, "Transferred to #{target_name}. #{reason}"}
      end
    )
  end

  @doc """
  Generate transfer tools for a list of target agent names.

  ## Example

      Handoff.transfer_tools(["analyst", "writer"])
      #=> [%Tool{name: "transfer_to_analyst", ...}, %Tool{name: "transfer_to_writer", ...}]
  """
  @spec transfer_tools([String.t()]) :: [Tool.t()]
  def transfer_tools(target_names) when is_list(target_names) do
    Enum.map(target_names, &transfer_tool/1)
  end

  @doc "Check if a tool call is a handoff transfer."
  @spec transfer?(FunctionCall.t()) :: boolean()
  def transfer?(%FunctionCall{name: name}) do
    String.starts_with?(name, @transfer_prefix)
  end

  @doc "Extract the target agent name from a transfer tool call. Returns `nil` if not a transfer."
  @spec target(FunctionCall.t()) :: String.t() | nil
  def target(%FunctionCall{name: name}) do
    if String.starts_with?(name, @transfer_prefix) do
      String.replace_prefix(name, @transfer_prefix, "")
    else
      nil
    end
  end

  @doc """
  Detect a handoff in a list of tool calls.

  Returns `{:handoff, target_name, call}` if a transfer tool is found,
  or `:none` if no handoff is present.

  ## Example

      calls = [%FunctionCall{name: "transfer_to_analyst", ...}]
      Handoff.detect(calls)
      #=> {:handoff, "analyst", %FunctionCall{...}}
  """
  @spec detect([FunctionCall.t()]) :: {:handoff, String.t(), FunctionCall.t()} | :none
  def detect(tool_calls) when is_list(tool_calls) do
    case Enum.find(tool_calls, &transfer?/1) do
      nil -> :none
      call -> {:handoff, target(call), call}
    end
  end

  @doc "Returns the transfer tool name prefix."
  @spec prefix() :: String.t()
  def prefix, do: @transfer_prefix
end
