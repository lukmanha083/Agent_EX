defmodule AgentEx.Memory.SemanticMemory.Cache do
  @moduledoc """
  ETS-based query cache for Tier 3 semantic memory embeddings.

  Avoids redundant embedding API calls by caching search results keyed
  by `{project_id, agent_id, query_hash}`. Cache hits are <1ms (ETS lookup)
  vs 50-200ms (OpenAI embedding API + pgvector search).

  TTL: 30 minutes (matches working memory idle timeout).
  Invalidated when new semantic memories are stored.
  """

  use GenServer

  alias AgentEx.Memory.SemanticMemory.Store

  require Logger

  @table :semantic_memory_cache
  @ttl_seconds 1800

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get cached search results or compute and cache them.
  Returns `{:ok, results}` or `{:error, reason}`.
  """
  def get_or_fetch(project_id, agent_id, query) do
    key = cache_key(project_id, agent_id, query)

    case lookup(key) do
      {:hit, results} ->
        Logger.debug("SemanticCache: hit for agent=#{agent_id}")
        {:ok, results}

      :miss ->
        Logger.debug("SemanticCache: miss for agent=#{agent_id}, fetching")
        fetch_and_cache(project_id, agent_id, query, key)
    end
  end

  @doc "Invalidate all cached entries for an agent (call after storing new memories)."
  def invalidate(project_id, agent_id) do
    match_spec = [{{{project_id, agent_id, :_}, :_, :_}, [], [true]}]

    count = :ets.select_delete(@table, match_spec)

    if count > 0 do
      Logger.debug("SemanticCache: invalidated #{count} entries for agent=#{agent_id}")
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  # --- Private ---

  defp cache_key(project_id, agent_id, query) do
    hash = :erlang.phash2(query)
    {project_id, agent_id, hash}
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{_key, results, timestamp}] ->
        age = System.monotonic_time(:second) - timestamp

        if age <= @ttl_seconds do
          {:hit, results}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp fetch_and_cache(project_id, agent_id, query, key) do
    case Store.search(project_id, agent_id, query) do
      {:ok, results} ->
        :ets.insert(@table, {key, results, System.monotonic_time(:second)})
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("SemanticCache: fetch failed: #{Exception.message(e)}")
      {:error, :cache_fetch_failed}
  end
end
