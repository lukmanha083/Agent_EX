defmodule AgentEx.ModelClient do
  @moduledoc """
  LLM API client — maps to AutoGen's `ChatCompletionClient`.

  Supports multiple providers:
  - `:openai` — OpenAI-compatible APIs (default)
  - `:openrouter` — Moonshot/Kimi APIs (OpenAI-compatible with built-in tools)
  - `:anthropic` — Anthropic Claude APIs (different message format)
  """

  alias AgentEx.Message
  alias AgentEx.Message.FunctionCall
  alias AgentEx.Tool

  require Logger

  @enforce_keys [:model]
  defstruct [
    :model,
    :api_key,
    :project_id,
    provider: :openai,
    base_url: "https://api.openai.com/v1"
  ]

  @type provider :: :openai | :openrouter | :anthropic

  @type t :: %__MODULE__{
          model: String.t(),
          api_key: String.t() | nil,
          project_id: integer() | nil,
          provider: provider(),
          base_url: String.t()
        }

  @provider_defaults %{
    openai: "https://api.openai.com/v1",
    openrouter: "https://openrouter.ai/api/v1",
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

  @doc "Create an OpenRouter client (access Kimi, DeepSeek, Gemini, etc.)."
  def openrouter(model, opts \\ []) do
    new(Keyword.merge(opts, model: model, provider: :openrouter))
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
    max_tokens = Keyword.get(opts, :max_tokens)
    thinking = Keyword.get(opts, :thinking, false)
    mcp_servers = Keyword.get(opts, :mcp_servers)

    body = encode_request(client, messages, tools, temperature, response_format)
    body = if max_tokens, do: Map.put(body, "max_tokens", max_tokens), else: body
    body = maybe_add_thinking(body, thinking, client)
    body = if mcp_servers, do: Map.put(body, "mcp_servers", mcp_servers), else: body
    headers = request_headers(client)
    url = request_url(client)

    do_request(url, body, headers, client.provider, _retries = 3, _backoff = 5_000)
  end

  defp do_request(url, body, headers, provider, retries, backoff) do
    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        with {:ok, message} <- parse_response(resp_body, provider) do
          usage = extract_usage(resp_body, provider)
          {:ok, %{message | usage: usage}}
        end

      {:ok, %{status: 429} = resp} when retries > 0 ->
        wait = parse_retry_after(resp) || backoff

        Logger.warning(
          "ModelClient: rate limited (429), retrying in #{div(wait, 1000)}s (#{retries} left)"
        )

        Process.sleep(wait)
        do_request(url, body, headers, provider, retries - 1, min(backoff * 2, 60_000))

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_retry_after(%{headers: headers}) when is_map(headers) do
    case Map.get(headers, "retry-after") do
      [seconds | _] -> parse_seconds(seconds)
      seconds when is_binary(seconds) -> parse_seconds(seconds)
      _ -> nil
    end
  end

  defp parse_retry_after(_), do: nil

  defp parse_seconds(str) do
    case Integer.parse(str) do
      {n, _} -> n * 1000
      :error -> nil
    end
  end

  @doc "Parse a raw API response body into a Message struct."
  def parse_response(body, provider \\ :openai)

  def parse_response(%{"choices" => [%{"message" => message} | _]}, provider)
      when provider in [:openai, :openrouter] do
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
    # Filter out thinking blocks — they're internal reasoning, not for conversation
    visible_blocks = Enum.reject(content_blocks, &(&1["type"] == "thinking"))

    # Handle both regular tool_use and MCP server-side tool_use
    tool_uses =
      Enum.filter(visible_blocks, &(&1["type"] in ["tool_use", "mcp_tool_use"]))

    if tool_uses != [] do
      calls =
        Enum.map(tool_uses, fn block ->
          id = block["id"]
          name = block["name"]
          input = block["input"]
          %FunctionCall{id: id, name: name, arguments: Jason.encode!(input)}
        end)

      {:ok, Message.assistant_tool_calls(calls)}
    else
      text_blocks = Enum.filter(visible_blocks, &(&1["type"] == "text"))

      text = Enum.map_join(text_blocks, "\n", & &1["text"])

      # Extract citations from text blocks if present
      citations = extract_citations(text_blocks)

      message = Message.assistant(text)

      message =
        if citations != [], do: %{message | metadata: %{citations: citations}}, else: message

      {:ok, message}
    end
  end

  def parse_response(other, _provider), do: {:error, {:unexpected_response, other}}

  # -- Request encoding --

  defp encode_request(%{provider: :anthropic} = client, messages, tools, temp, resp_fmt) do
    {system_text, chat_messages} = Message.encode_for_anthropic(messages)

    %{"model" => client.model, "max_tokens" => 4096, "messages" => chat_messages}
    |> maybe_put("system", anthropic_system_with_cache(system_text))
    |> maybe_add_tools(tools, :anthropic)
    |> maybe_cache_last_tool(:anthropic)
    |> maybe_add_temperature(temp, :anthropic)
    |> maybe_add_response_format(resp_fmt, :anthropic)
    |> Map.put("citations", %{"enabled" => true})
    |> Map.put("context_management", anthropic_context_management())
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

  # Mark last tool with cache_control for Anthropic prompt caching
  defp maybe_cache_last_tool(%{"tools" => [_ | _] = tools} = body, :anthropic) do
    {init, [last]} = Enum.split(tools, -1)
    cached_last = Map.put(last, "cache_control", %{"type" => "ephemeral"})
    %{body | "tools" => init ++ [cached_last]}
  end

  defp maybe_cache_last_tool(body, _), do: body

  # -- Built-in thinking/reasoning per provider --

  defp maybe_add_thinking(body, false, _client), do: body

  # Anthropic (direct API): adaptive thinking — model decides WHEN to think
  # More efficient than always-on: skips reasoning for simple tool calls,
  # engages deep thinking for complex planning/analysis
  defp maybe_add_thinking(body, true, %{provider: :anthropic}) do
    body
    |> Map.put("thinking", %{"type" => "adaptive"})
    |> Map.update("max_tokens", 8192, fn current -> max(current, 8192) end)
  end

  # OpenRouter: unified reasoning parameter — works across all models
  # that support thinking (Claude, Kimi, DeepSeek, o-series, Gemini)
  defp maybe_add_thinking(body, true, %{provider: :openrouter}) do
    body
    |> Map.put("reasoning", %{"effort" => "low"})
    |> Map.update("max_tokens", 8192, fn current -> max(current, 8192) end)
  end

  # OpenAI (direct API): reasoning_effort for o-series models
  defp maybe_add_thinking(body, true, %{provider: :openai, model: model}) do
    if String.starts_with?(String.downcase(model), "o3") or
         String.starts_with?(String.downcase(model), "o4") do
      Map.put(body, "reasoning_effort", "low")
    else
      body
    end
  end

  # Other providers: no built-in thinking (falls back to 2-call reasoning_first)
  defp maybe_add_thinking(body, _thinking, _client), do: body

  # -- Temperature (Moonshot/Anthropic clamp to [0, 1]) --

  # -- Temperature --

  defp maybe_add_temperature(body, nil, _provider), do: body

  defp maybe_add_temperature(body, temp, provider)
       when provider in [:openrouter, :anthropic] do
    Map.put(body, "temperature", temp |> Kernel.max(0) |> Kernel.min(1))
  end

  defp maybe_add_temperature(body, temp, _provider) do
    Map.put(body, "temperature", temp)
  end

  # -- Response format (Moonshot does not support it) --

  defp maybe_add_response_format(body, nil, _provider), do: body
  defp maybe_add_response_format(body, _fmt, :openrouter), do: body

  defp maybe_add_response_format(body, fmt, _provider) do
    Map.put(body, "response_format", fmt)
  end

  # -- Headers --

  @anthropic_betas [
    "prompt-caching-2024-07-31",
    "token-efficient-tools-2025-02-19",
    "context-management-2025-06-27",
    "interleaved-thinking-2025-05-14"
  ]

  defp request_headers(%{provider: :anthropic} = client) do
    [
      {"x-api-key", resolve_api_key(client)},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", Enum.join(@anthropic_betas, ",")},
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
    AgentEx.Vault.resolve_key(pid, "llm:anthropic")
  end

  defp resolve_api_key(%{provider: :openrouter, project_id: pid}) do
    AgentEx.Vault.resolve_key(pid, "llm:openrouter")
  end

  defp resolve_api_key(%{project_id: pid}) do
    AgentEx.Vault.resolve_key(pid, "llm:openai")
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

  # -- Citation extraction --

  defp extract_citations(text_blocks) do
    text_blocks
    |> Enum.flat_map(&get_block_citations/1)
  end

  defp get_block_citations(%{"citations" => citations}) when is_list(citations) do
    Enum.map(citations, &format_citation/1)
  end

  defp get_block_citations(_), do: []

  defp format_citation(cite) do
    %{
      type: cite["type"],
      cited_text: cite["cited_text"],
      document_title: cite["document_title"],
      start: cite["start_char_index"] || cite["start_page_number"] || cite["start_block_index"],
      end_pos: cite["end_char_index"] || cite["end_page_number"] || cite["end_block_index"],
      url: cite["url"]
    }
  end

  # -- Helpers --

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Convert system text to Anthropic cache-friendly format:
  # array of content blocks with cache_control on the last block
  defp anthropic_system_with_cache(nil), do: nil
  defp anthropic_system_with_cache(""), do: nil

  defp anthropic_system_with_cache(text) do
    [%{"type" => "text", "text" => text, "cache_control" => %{"type" => "ephemeral"}}]
  end

  # Server-side context management — Anthropic handles compression automatically.
  # Replaces our manual compress_delegation_rounds with three strategies:
  # 1. Clear old tool uses when context exceeds 80k tokens (keep last 5)
  # 2. Clear old thinking blocks (keep last 3 turns)
  # 3. Auto-compact context when exceeding 120k tokens
  defp anthropic_context_management do
    %{
      "edits" => [
        %{
          "type" => "clear_tool_uses_20250919",
          "trigger" => %{"type" => "input_tokens", "value" => 80_000},
          "keep" => %{"type" => "tool_uses", "value" => 5},
          "clear_tool_inputs" => true
        },
        %{
          "type" => "clear_thinking_20251015",
          "keep" => %{"type" => "thinking_turns", "value" => 3}
        },
        %{
          "type" => "compact_20260112",
          "trigger" => %{"type" => "input_tokens", "value" => 120_000}
        }
      ]
    }
  end

  @doc """
  Build MCP server config for Anthropic's server-side MCP execution.

  When passed to the API, Claude can call MCP tools directly without
  going through our ToolCallerLoop. Useful for remote tool servers.

  ## Example

      mcp_config = ModelClient.anthropic_mcp_servers([
        %{name: "github", url: "https://mcp.github.com/sse"}
      ])
      ModelClient.create(client, messages, mcp_servers: mcp_config)
  """
  def anthropic_mcp_servers(servers) when is_list(servers) do
    Enum.map(servers, fn server ->
      name = Map.get(server, :name) || Map.get(server, "name")
      url = Map.get(server, :url) || Map.get(server, "url")
      token = Map.get(server, :token) || Map.get(server, "token")

      %{
        "type" => "url",
        "name" => name,
        "url" => url,
        "authorization_token" => token
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end)
  end
end
