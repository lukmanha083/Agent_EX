defmodule AgentEx.ModelClient do
  @moduledoc """
  LLM API client — maps to AutoGen's `ChatCompletionClient`.

  Supports multiple providers:
  - `:openai` — OpenAI-compatible APIs (default)
  - `:moonshot` — Moonshot/Kimi APIs (OpenAI-compatible with built-in tools)
  - `:anthropic` — Anthropic Claude APIs (different message format)
  """

  alias AgentEx.Message
  alias AgentEx.Message.FunctionCall
  alias AgentEx.Tool

  @enforce_keys [:model]
  defstruct [
    :model,
    :api_key,
    :project_id,
    provider: :openai,
    base_url: "https://api.openai.com/v1"
  ]

  @type provider :: :openai | :moonshot | :anthropic

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          project_id: integer() | nil,
          provider: provider(),
          base_url: String.t()
        }

  @provider_defaults %{
    openai: "https://api.openai.com/v1",
    moonshot: "https://api.moonshot.cn/v1",
    anthropic: "https://api.anthropic.com"
  }

  @doc "Create a new ModelClient with explicit options."
  def new(opts) do
    provider = Keyword.get(opts, :provider, :openai)
    base_url = Keyword.get(opts, :base_url, Map.fetch!(@provider_defaults, provider))

    opts
    |> Keyword.put(:base_url, base_url)
    |> then(&struct!(__MODULE__, &1))
  end

  @doc "Create an OpenAI client."
  def openai(model, opts \\ []) do
    new(Keyword.merge(opts, model: model, provider: :openai))
  end

  @doc "Create a Moonshot/Kimi client."
  def moonshot(model, opts \\ []) do
    new(Keyword.merge(opts, model: model, provider: :moonshot))
  end

  @doc "Create an Anthropic/Claude client."
  def anthropic(model, opts \\ []) do
    new(Keyword.merge(opts, model: model, provider: :anthropic))
  end

  @doc """
  Send a chat completion request to the LLM.

  Returns either:
  - `{:ok, %Message{role: :assistant}}` — text or tool call response
  - `{:error, reason}` — API error
  """
  def create(%__MODULE__{} = client, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    temperature = Keyword.get(opts, :temperature)
    response_format = Keyword.get(opts, :response_format)

    body = encode_request(client, messages, tools, temperature, response_format)
    headers = request_headers(client)
    url = request_url(client)

    case Req.post(url, json: body, headers: headers) do
      {:ok, %{status: 200, body: resp_body}} ->
        with {:ok, message} <- parse_response(resp_body, client.provider) do
          usage = extract_usage(resp_body, client.provider)
          {:ok, %{message | usage: usage}}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Parse a raw API response body into a Message struct."
  def parse_response(body, provider \\ :openai)

  def parse_response(%{"choices" => [%{"message" => message} | _]}, provider)
      when provider in [:openai, :moonshot] do
    case message do
      %{"tool_calls" => calls} when is_list(calls) and calls != [] ->
        parsed =
          Enum.map(calls, fn tc ->
            %{"id" => id, "function" => %{"name" => name, "arguments" => args}} = tc
            %FunctionCall{id: id, name: name, arguments: args}
          end)

        {:ok, Message.assistant_tool_calls(parsed)}

      %{"content" => content} ->
        {:ok, Message.assistant(content || "")}
    end
  end

  def parse_response(%{"content" => content_blocks}, :anthropic)
      when is_list(content_blocks) do
    tool_uses = Enum.filter(content_blocks, &(&1["type"] == "tool_use"))

    if tool_uses != [] do
      calls =
        Enum.map(tool_uses, fn %{"id" => id, "name" => name, "input" => input} ->
          %FunctionCall{id: id, name: name, arguments: Jason.encode!(input)}
        end)

      {:ok, Message.assistant_tool_calls(calls)}
    else
      text =
        content_blocks
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])

      {:ok, Message.assistant(text)}
    end
  end

  def parse_response(other, _provider), do: {:error, {:unexpected_response, other}}

  # -- Request encoding --

  defp encode_request(%{provider: :anthropic} = client, messages, tools, temp, resp_fmt) do
    {system_text, chat_messages} = Message.encode_for_anthropic(messages)

    %{"model" => client.model, "max_tokens" => 4096, "messages" => chat_messages}
    |> maybe_put("system", system_text)
    |> maybe_add_tools(tools, :anthropic)
    |> maybe_add_temperature(temp, :anthropic)
    |> maybe_add_response_format(resp_fmt, :anthropic)
  end

  defp encode_request(%{provider: provider} = client, messages, tools, temp, resp_fmt) do
    %{"model" => client.model, "messages" => encode_messages_openai(messages)}
    |> maybe_add_tools(tools, provider)
    |> maybe_add_temperature(temp, provider)
    |> maybe_add_response_format(resp_fmt, provider)
  end

  # -- OpenAI message encoding (also used by Moonshot) --

  defp encode_messages_openai(messages) do
    Enum.flat_map(messages, &List.wrap(encode_message_openai(&1)))
  end

  defp encode_message_openai(%Message{role: :tool, content: results})
       when is_list(results) do
    Enum.map(results, fn %Message.FunctionResult{} = r ->
      %{"role" => "tool", "tool_call_id" => r.call_id, "content" => r.content}
    end)
  end

  defp encode_message_openai(%Message{role: :assistant, tool_calls: calls})
       when is_list(calls) do
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

  defp encode_message_openai(%Message{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  # -- Tools --

  defp maybe_add_tools(body, [], _provider), do: body

  defp maybe_add_tools(body, tools, provider) do
    Map.put(body, "tools", Enum.map(tools, &Tool.to_schema(&1, provider)))
  end

  # -- Temperature (Moonshot/Anthropic clamp to [0, 1]) --

  defp maybe_add_temperature(body, nil, _provider), do: body

  defp maybe_add_temperature(body, temp, provider)
       when provider in [:moonshot, :anthropic] do
    Map.put(body, "temperature", temp |> Kernel.max(0) |> Kernel.min(1))
  end

  defp maybe_add_temperature(body, temp, _provider) do
    Map.put(body, "temperature", temp)
  end

  # -- Response format (Moonshot does not support it) --

  defp maybe_add_response_format(body, nil, _provider), do: body
  defp maybe_add_response_format(body, _fmt, :moonshot), do: body

  defp maybe_add_response_format(body, fmt, _provider) do
    Map.put(body, "response_format", fmt)
  end

  # -- Headers --

  defp request_headers(%{provider: :anthropic} = client) do
    [
      {"x-api-key", resolve_api_key(client)},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  defp request_headers(client) do
    [{"authorization", "Bearer #{resolve_api_key(client)}"}]
  end

  # -- URL --

  defp request_url(%{provider: :anthropic, base_url: base_url}) do
    "#{base_url}/v1/messages"
  end

  defp request_url(%{base_url: base_url}), do: "#{base_url}/chat/completions"

  # -- API key resolution (per-provider, config then env) --

  defp resolve_api_key(%{api_key: key}) when is_binary(key) and key != "", do: key

  defp resolve_api_key(%{provider: :anthropic, project_id: pid}) do
    AgentEx.Vault.resolve_key(pid, "llm:anthropic", :anthropic_api_key, "ANTHROPIC_API_KEY")
  end

  defp resolve_api_key(%{provider: :moonshot, project_id: pid}) do
    AgentEx.Vault.resolve_key(pid, "llm:moonshot", :moonshot_api_key, "MOONSHOT_API_KEY")
  end

  defp resolve_api_key(%{project_id: pid}) do
    AgentEx.Vault.resolve_key(pid, "llm:openai", :openai_api_key, "OPENAI_API_KEY")
  end

  # -- Usage extraction --

  defp extract_usage(
         %{"usage" => %{"input_tokens" => input, "output_tokens" => output}},
         :anthropic
       ) do
    %{input_tokens: input, output_tokens: output}
  end

  defp extract_usage(
         %{"usage" => %{"prompt_tokens" => input, "completion_tokens" => output}},
         _provider
       ) do
    %{input_tokens: input, output_tokens: output}
  end

  defp extract_usage(_, _), do: nil

  # -- Helpers --

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
