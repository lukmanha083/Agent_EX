defmodule AgentEx.Memory.SemanticMemory.Store do
  @moduledoc """
  Tier 3: Semantic memory using vector embeddings stored in HelixDB.
  All operations are scoped by `agent_id` — vectors are tagged on store
  and filtered on retrieval.
  """

  use GenServer

  @behaviour AgentEx.Memory.Tier

  alias AgentEx.Memory.Embeddings
  alias AgentEx.Memory.SemanticMemory.Client

  require Logger

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def store(agent_id, text, type \\ "general", session_id \\ "") do
    GenServer.call(__MODULE__, {:store, agent_id, text, type, session_id}, 30_000)
  end

  def search(agent_id, query, limit \\ 5) do
    GenServer.call(__MODULE__, {:search, agent_id, query, limit}, 30_000)
  end

  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages(agent_id, query) when is_binary(query) do
    case search(agent_id, query) do
      {:ok, results} when results != [] ->
        content =
          results
          |> Enum.map_join("\n", fn r ->
            "- #{r["content"] || get_in(r, ["properties", "content"]) || inspect(r)}"
          end)

        [%{role: "system", content: "## Relevant Past Context\n#{content}"}]

      _ ->
        []
    end
  end

  @impl AgentEx.Memory.Tier
  def token_estimate(agent_id, query) when is_binary(query) do
    case search(agent_id, query) do
      {:ok, results} ->
        Enum.reduce(results, 0, fn r, acc ->
          content = r["content"] || get_in(r, ["properties", "content"]) || ""
          acc + div(String.length(content), 4)
        end)

      _ ->
        0
    end
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:store, agent_id, text, type, session_id}, _from, state) do
    result =
      with {:ok, vector} <- Embeddings.embed(text) do
        Client.query("AddMemory", %{
          vector: vector,
          content: text,
          type: type,
          agent_id: agent_id,
          session_id: session_id
        })
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:search, agent_id, query, limit}, _from, state) do
    # Over-fetch then filter by agent_id client-side
    fetch_limit = limit * 3

    result =
      with {:ok, vector} <- Embeddings.embed(query),
           {:ok, response} <-
             Client.query("SearchMemory", %{vector: vector, limit: fetch_limit}) do
        results =
          response
          |> parse_search_results()
          |> Enum.filter(fn r ->
            r_agent = r["agent_id"] || get_in(r, ["properties", "agent_id"])
            r_agent == agent_id
          end)
          |> Enum.take(limit)

        {:ok, results}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:delete, id}, _from, state) do
    result = Client.query("DeleteMemory", %{id: id})
    {:reply, result, state}
  end

  defp parse_search_results(%{"results" => results}) when is_list(results), do: results
  defp parse_search_results(results) when is_list(results), do: results
  defp parse_search_results(response), do: [response]
end
