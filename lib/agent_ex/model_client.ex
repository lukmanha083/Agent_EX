defmodule AgentEx.ModelClient do
  @moduledoc """
  LLM API client — maps to AutoGen's `ChatCompletionClient`.

  Handles communication with OpenAI-compatible APIs.
  Uses Req for HTTP requests.
  """

  alias AgentEx.Message
  alias AgentEx.Message.FunctionCall
  alias AgentEx.Tool

  @enforce_keys [:model]
  defstruct [:model, :api_key, base_url: "https://api.openai.com/v1"]

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t()
        }

  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Send a chat completion request to the LLM.

  Returns either:
  - `{:ok, %Message{role: :assistant, content: "text"}}` — text response
  - `{:ok, %Message{role: :assistant, tool_calls: [%FunctionCall{}, ...]}}` — tool calls
  - `{:error, reason}` — API error
  """
  def create(%__MODULE__{} = client, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    temperature = Keyword.get(opts, :temperature)
    response_format = Keyword.get(opts, :response_format)

    body =
      %{
        "model" => client.model,
        "messages" => Enum.map(messages, &encode_message/1)
      }
      |> maybe_add_tools(tools)
      |> maybe_add_temperature(temperature)
      |> maybe_add_response_format(response_format)

    case Req.post(
           "#{client.base_url}/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer #{resolve_api_key(client)}"}]
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Encoding messages for the API --

  defp encode_message(%Message{role: :tool, content: results}) when is_list(results) do
    # Each tool result becomes a separate message in OpenAI format
    # But we return a list here — caller must flatten
    Enum.map(results, fn %Message.FunctionResult{} = r ->
      %{
        "role" => "tool",
        "tool_call_id" => r.call_id,
        "content" => r.content
      }
    end)
  end

  defp encode_message(%Message{role: :assistant, tool_calls: calls}) when is_list(calls) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" =>
        Enum.map(calls, fn %FunctionCall{} = c ->
          %{
            "id" => c.id,
            "type" => "function",
            "function" => %{"name" => c.name, "arguments" => c.arguments}
          }
        end)
    }
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &Tool.to_schema/1))
  end

  defp maybe_add_temperature(body, nil), do: body
  defp maybe_add_temperature(body, temp), do: Map.put(body, "temperature", temp)

  defp maybe_add_response_format(body, nil), do: body
  defp maybe_add_response_format(body, fmt), do: Map.put(body, "response_format", fmt)

  # -- Parsing API response --

  defp parse_response(%{"choices" => [%{"message" => message} | _]}) do
    case message do
      %{"tool_calls" => tool_calls} when is_list(tool_calls) and tool_calls != [] ->
        calls =
          Enum.map(tool_calls, fn %{"id" => id, "function" => %{"name" => name, "arguments" => args}} ->
            %FunctionCall{id: id, name: name, arguments: args}
          end)

        {:ok, Message.assistant_tool_calls(calls)}

      %{"content" => content} ->
        {:ok, Message.assistant(content || "")}
    end
  end

  defp parse_response(other), do: {:error, {:unexpected_response, other}}

  defp resolve_api_key(%{api_key: nil}), do: System.get_env("OPENAI_API_KEY") || ""
  defp resolve_api_key(%{api_key: key}), do: key
end
