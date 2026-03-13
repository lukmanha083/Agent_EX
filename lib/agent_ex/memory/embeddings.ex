defmodule AgentEx.Memory.Embeddings do
  @moduledoc """
  OpenAI embedding API client.
  Uses text-embedding-3-small (1536 dimensions).
  """

  require Logger

  @url "https://api.openai.com/v1/embeddings"

  def embed(text) when is_binary(text) do
    api_key = resolve_api_key()
    model = Application.get_env(:agent_ex, :embedding_model, "text-embedding-3-small")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      body = %{input: text, model: model}

      case Req.post(@url,
             json: body,
             headers: [{"authorization", "Bearer #{api_key}"}],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
          {:ok, embedding}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Embedding error: status=#{status} body=#{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Embedding request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def embed_batch(texts) when is_list(texts) do
    api_key = resolve_api_key()
    model = Application.get_env(:agent_ex, :embedding_model, "text-embedding-3-small")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      body = %{input: texts, model: model}

      case Req.post(@url,
             json: body,
             headers: [{"authorization", "Bearer #{api_key}"}],
             receive_timeout: 60_000
           ) do
        {:ok, %{status: 200, body: %{"data" => data}}} ->
          embeddings =
            data
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])

          {:ok, embeddings}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_api_key do
    Application.get_env(:agent_ex, :openai_api_key) || System.get_env("OPENAI_API_KEY")
  end
end
