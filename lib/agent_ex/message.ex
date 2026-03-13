defmodule AgentEx.Message do
  @moduledoc """
  Message types used in the agent system.

  Maps to AutoGen's LLMMessage types:
  - SystemMessage    → %Message{role: :system}
  - UserMessage      → %Message{role: :user}
  - AssistantMessage → %Message{role: :assistant}
  - FunctionCall     → %FunctionCall{}
  - FunctionExecutionResult → %FunctionResult{}
  - FunctionExecutionResultMessage → %Message{role: :tool, content: [%FunctionResult{}]}
  """

  defmodule FunctionCall do
    @moduledoc "A tool/function call requested by the LLM."
    @enforce_keys [:id, :name, :arguments]
    defstruct [:id, :name, :arguments]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            arguments: String.t()
          }
  end

  defmodule FunctionResult do
    @moduledoc "The result of executing a tool/function call."
    @enforce_keys [:call_id, :name, :content]
    defstruct [:call_id, :name, :content, is_error: false]

    @type t :: %__MODULE__{
            call_id: String.t(),
            name: String.t(),
            content: String.t(),
            is_error: boolean()
          }
  end

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :source, :tool_calls]

  @type role :: :system | :user | :assistant | :tool
  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | [FunctionResult.t()],
          source: String.t() | nil,
          tool_calls: [FunctionCall.t()] | nil
        }

  def system(content), do: %__MODULE__{role: :system, content: content}
  def user(content, source \\ "user"), do: %__MODULE__{role: :user, content: content, source: source}

  def assistant(content, source \\ "assistant"),
    do: %__MODULE__{role: :assistant, content: content, source: source}

  def assistant_tool_calls(tool_calls, source \\ "assistant"),
    do: %__MODULE__{role: :assistant, content: "", tool_calls: tool_calls, source: source}

  def tool_results(results) when is_list(results),
    do: %__MODULE__{role: :tool, content: results}
end
