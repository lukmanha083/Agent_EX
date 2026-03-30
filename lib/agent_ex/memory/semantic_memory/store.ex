defmodule AgentEx.Memory.SemanticMemory.Store do
  @moduledoc """
  Tier 3: Semantic memory using vector embeddings stored in HelixDB.
  All operations are scoped by `(user_id, project_id, agent_id)` — vectors
  are tagged on store and filtered on retrieval.
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

  def store(user_id, project_id, agent_id, text, type \\ "general", session_id \\ "") do
    GenServer.call(
      __MODULE__,
      {:store, user_id, project_id, agent_id, text, type, session_id},
      30_000
    )
  end

  def search(user_id, project_id, agent_id, query, limit \\ 5) do
    GenServer.call(__MODULE__, {:search, user_id, project_id, agent_id, query, limit}, 30_000)
  end

  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc """
  Delete all semantic memories for an agent.

  Uses a broad vector search + client-side agent_id filter since HelixDB
  doesn't support property-based queries. Runs in batches until no more
  matches are found.
  """
  def delete_by_agent(user_id, project_id, agent_id) do
    GenServer.call(__MODULE__, {:delete_by_agent, user_id, project_id, agent_id}, 60_000)
  end

  @doc "Delete all semantic memories for a project (scoped by project_id metadata)."
  def delete_by_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:delete_by_project, user_id, project_id}, 60_000)
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages({user_id, project_id, agent_id}, query) when is_binary(query) do
    case search(user_id, project_id, agent_id, query) do
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
  def token_estimate({user_id, project_id, agent_id}, query) when is_binary(query) do
    case search(user_id, project_id, agent_id, query) do
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
  def handle_call({:store, user_id, project_id, agent_id, text, type, session_id}, _from, state) do
    result =
      with {:ok, vector} <- Embeddings.embed(text) do
        Client.query("AddMemory", %{
          vector: vector,
          content: text,
          memory_type: type,
          agent_id: agent_id,
          user_id: user_id,
          project_id: project_id,
          session_id: session_id
        })
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:search, user_id, project_id, agent_id, query, limit}, _from, state) do
    # Over-fetch then filter by (user_id, project_id, agent_id) client-side
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
            r_uid = r["user_id"] || get_in(r, ["properties", "user_id"])
            r_pid = r["project_id"] || get_in(r, ["properties", "project_id"])

            r_agent == agent_id and
              to_string(r_uid) == to_string(user_id) and
              to_string(r_pid) == to_string(project_id)
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

  @impl GenServer
  def handle_call({:delete_by_agent, user_id, project_id, agent_id}, _from, state) do
    filter = %{
      "agent_id" => to_string(agent_id),
      "user_id" => to_string(user_id),
      "project_id" => to_string(project_id)
    }

    result = do_delete_by_filter(filter)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:delete_by_project, user_id, project_id}, _from, state) do
    filter = %{
      "user_id" => to_string(user_id),
      "project_id" => to_string(project_id)
    }

    result = do_delete_by_filter(filter)
    {:reply, result, state}
  end

  @batch_size 500
  @zero_vector List.duplicate(0.0, 1536)

  defp do_delete_by_filter(filter, total_deleted \\ 0) do
    case Client.query("SearchMemory", %{vector: @zero_vector, limit: @batch_size}) do
      {:ok, response} ->
        ids =
          response
          |> parse_search_results()
          |> Enum.filter(&matches_filter?(&1, filter))
          |> Enum.map(fn r -> r["id"] || get_in(r, ["properties", "id"]) end)
          |> Enum.reject(&is_nil/1)

        Enum.each(ids, &Client.query("DeleteMemory", %{id: &1}))

        if ids == [] do
          {:ok, total_deleted}
        else
          do_delete_by_filter(filter, total_deleted + length(ids))
        end

      {:error, reason} ->
        Logger.warning(
          "Semantic memory cleanup for #{inspect(filter)} failed: #{inspect(reason)}"
        )

        {:ok, total_deleted}
    end
  end

  defp matches_filter?(record, filter) do
    Enum.all?(filter, fn {field, value} ->
      r_val = record[field] || get_in(record, ["properties", field])
      to_string(r_val) == value
    end)
  end

  defp parse_search_results(%{"results" => results}) when is_list(results), do: results
  defp parse_search_results(results) when is_list(results), do: results
  defp parse_search_results(response), do: [response]
end
