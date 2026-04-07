defmodule AgentEx.Memory.Embeddings do
  @moduledoc """
  OpenAI embedding API client.
  Uses text-embedding-3-small (1536 dimensions).
  Supports project-scoped API keys via Vault.
  """

  require Logger

  @url "https://api.openai.com/v1/embeddings"

  @doc "Embed a single text. Accepts optional `project_id` for vault key resolution."
  def embed(text, opts \\ []) when is_binary(text) do
    project_id = Keyword.get(opts, :project_id)
    api_key = resolve_api_key(project_id)
    model = Application.get_env(:agent_ex, :embedding_model, "text-embedding-3-small")

    if api_key == "" or is_nil(api_key) do
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

  @doc "Embed a batch of texts. Accepts optional `project_id` for vault key resolution."
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    project_id = Keyword.get(opts, :project_id)
    api_key = resolve_api_key(project_id)
    model = Application.get_env(:agent_ex, :embedding_model, "text-embedding-3-small")

    if api_key == "" or is_nil(api_key) do
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

  defp resolve_api_key(project_id) do
    case AgentEx.Vault.resolve_key(project_id, "embedding:openai") do
      key when is_binary(key) and key != "" -> key
      _ -> System.get_env("OPENAI_API_KEY") || ""
    end
  end
end
