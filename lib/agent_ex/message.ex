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

  def user(content, source \\ "user"),
    do: %__MODULE__{role: :user, content: content, source: source}

  def assistant(content, source \\ "assistant"),
    do: %__MODULE__{role: :assistant, content: content, source: source}

  def assistant_tool_calls(tool_calls, source \\ "assistant"),
    do: %__MODULE__{role: :assistant, content: "", tool_calls: tool_calls, source: source}

  def tool_results(results) when is_list(results),
    do: %__MODULE__{role: :tool, content: results}

  @doc """
  Encode messages for Anthropic's API format.

  Returns `{system_text, encoded_messages}` where:
  - `system_text` — combined system message text (or nil if none)
  - `encoded_messages` — list of message maps for the `messages` param
  """
  @spec encode_for_anthropic([t()]) :: {String.t() | nil, [map()]}
  def encode_for_anthropic(messages) do
    {system_msgs, chat_msgs} = Enum.split_with(messages, &(&1.role == :system))

    system_text =
      case system_msgs do
        [] -> nil
        msgs -> Enum.map_join(msgs, "\n\n", & &1.content)
      end

    encoded = Enum.flat_map(chat_msgs, &encode_anthropic_message/1)
    {system_text, encoded}
  end

  defp encode_anthropic_message(%__MODULE__{role: :assistant, tool_calls: calls})
       when is_list(calls) and calls != [] do
    content =
      Enum.map(calls, fn %FunctionCall{} = c ->
        %{
          "type" => "tool_use",
          "id" => c.id,
          "name" => c.name,
          "input" => Jason.decode!(c.arguments)
        }
      end)

    [%{"role" => "assistant", "content" => content}]
  end

  defp encode_anthropic_message(%__MODULE__{role: :tool, content: results})
       when is_list(results) do
    content =
      Enum.map(results, fn %FunctionResult{} = r ->
        block = %{
          "type" => "tool_result",
          "tool_use_id" => r.call_id,
          "content" => r.content
        }

        if r.is_error, do: Map.put(block, "is_error", true), else: block
      end)

    [%{"role" => "user", "content" => content}]
  end

  defp encode_anthropic_message(%__MODULE__{role: :system}), do: []

  defp encode_anthropic_message(%__MODULE__{role: role, content: content}) do
    [%{"role" => to_string(role), "content" => content}]
  end
end
