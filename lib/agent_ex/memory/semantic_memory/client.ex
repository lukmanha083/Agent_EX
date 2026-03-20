defmodule AgentEx.Memory.SemanticMemory.Client do
  @moduledoc """
  HTTP client for HelixDB.
  Sends HelixQL queries via POST to the HelixDB HTTP API.
  Shared by SemanticMemory.Store and KnowledgeGraph modules.
  """

  require Logger

  def query(query_name, params \\ %{}) do
    url = "#{base_url()}/#{query_name}"

    case Req.post(url, json: params, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok,
       %{status: 500, body: %{"error" => "Vector error: no entry point found for hnsw index"}}} ->
        # Empty vector index — no data stored yet, return empty results
        {:ok, []}

      {:ok, %{status: status, body: body}} ->
        Logger.error("HelixDB error: query=#{query_name} status=#{status} body=#{inspect(body)}")
        {:error, {:helix_error, status, body}}

      {:error, reason} ->
        Logger.error("HelixDB request failed: query=#{query_name} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp base_url do
    Application.get_env(:agent_ex, :helix_db_url, "http://localhost:6969")
  end
end
