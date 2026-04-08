defmodule AgentEx.Memory.ProceduralMemory.Store do
  @moduledoc """
  Tier 4: Procedural memory (learned skills) using ETS + per-project DETS.

  Stores `Skill` structs keyed by `{user_id, project_id, agent_id, skill_name}`.
  DETS files are opened lazily per-project via DetsManager.

  ## Upgrades
  - `write_concurrency: true` for parallel writes
  - 5-second sync interval (down from 30s)
  - ETS `match_object` patterns instead of `foldl` for faster scans
  - Auto-prune low-confidence skills (< 0.3 after 5+ observations)
  """

  use GenServer

  @behaviour AgentEx.Memory.Tier

  alias AgentEx.DetsManager
  alias AgentEx.Memory.ProceduralMemory.Skill

  require Logger

  @store_name :procedural_memory
  @default_sync_interval :timer.seconds(5)
  @prune_min_observations 5
  @prune_confidence_threshold 0.3

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store or update a skill."
  def put(user_id, project_id, agent_id, %Skill{} = skill) do
    GenServer.call(__MODULE__, {:put, user_id, project_id, agent_id, skill})
  end

  @doc "Direct ETS lookup by `(user_id, project_id, agent_id, skill_name)`."
  def get(user_id, project_id, agent_id, skill_name) do
    case :ets.lookup(@store_name, {user_id, project_id, agent_id, skill_name}) do
      [{_key, skill}] -> {:ok, skill}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "Return all skills for `(user_id, project_id, agent_id)`. Uses match_object."
  def all(user_id, project_id, agent_id) do
    pattern = {{user_id, project_id, agent_id, :_}, :_}

    :ets.match_object(@store_name, pattern)
    |> Enum.map(fn {_key, skill} -> skill end)
  rescue
    ArgumentError -> []
  end

  @doc "Return skills matching a domain."
  def get_by_domain(user_id, project_id, agent_id, domain) do
    all(user_id, project_id, agent_id)
    |> Enum.filter(&(&1.domain == domain))
  end

  @doc "Return top skills sorted by confidence descending."
  def get_top_skills(user_id, project_id, agent_id, limit \\ 10) do
    user_id
    |> all(project_id, agent_id)
    |> Enum.sort_by(& &1.confidence, :desc)
    |> Enum.take(limit)
  end

  @doc "Delete a single skill."
  def delete(user_id, project_id, agent_id, skill_name) do
    GenServer.call(__MODULE__, {:delete, user_id, project_id, agent_id, skill_name})
  end

  @doc "Delete all skills for an agent."
  def delete_all(user_id, project_id, agent_id) do
    GenServer.call(__MODULE__, {:delete_all, user_id, project_id, agent_id})
  end

  @doc "Delete all skills for a project (cascade)."
  def delete_by_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:delete_by_project, user_id, project_id})
  end

  @doc "Hydrate a project's procedural memory from DETS into ETS."
  def hydrate_project(root_path) do
    GenServer.call(__MODULE__, {:hydrate_project, root_path})
  end

  @doc "Evict a project's data from ETS."
  def evict_project(user_id, project_id) do
    GenServer.call(__MODULE__, {:evict_project, user_id, project_id})
  end

  @doc """
  Prune low-confidence skills for an agent.

  Removes skills with confidence < threshold after min_observations.
  Returns the number of pruned skills.
  """
  def prune(user_id, project_id, agent_id, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @prune_confidence_threshold)
    min_obs = Keyword.get(opts, :min_observations, @prune_min_observations)

    skills = all(user_id, project_id, agent_id)

    prunable =
      Enum.filter(skills, fn skill ->
        total = skill.success_count + skill.failure_count
        total >= min_obs and skill.confidence < threshold
      end)

    Enum.each(prunable, fn skill ->
      delete(user_id, project_id, agent_id, skill.name)
    end)

    if prunable != [] do
      names = Enum.map_join(prunable, ", ", & &1.name)
      Logger.info("ProceduralMemory: pruned #{length(prunable)} low-confidence skills: #{names}")
    end

    {:ok, length(prunable)}
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages({user_id, project_id, agent_id}, _identifier \\ nil) do
    skills = get_top_skills(user_id, project_id, agent_id, 10)

    if skills == [] do
      []
    else
      content = format_skills(skills)
      [%{role: "system", content: "## Learned Skills & Strategies\n#{content}"}]
    end
  end

  @impl AgentEx.Memory.Tier
  def token_estimate({user_id, project_id, agent_id}, _identifier \\ nil) do
    skills = all(user_id, project_id, agent_id)

    Enum.reduce(skills, 0, fn skill, acc ->
      text = "#{skill.name}: #{skill.strategy}"
      acc + div(String.length(text), 4)
    end)
  end

  # --- Server callbacks ---

  @impl GenServer
  def init(_opts) do
    sync_interval =
      Application.get_env(:agent_ex, :procedural_memory_sync_interval, @default_sync_interval)

    ets_table =
      :ets.new(@store_name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_sync(sync_interval)

    {:ok, %{ets_table: ets_table, sync_interval: sync_interval}}
  end

  @impl GenServer
  def handle_call({:put, user_id, project_id, agent_id, %Skill{} = skill}, _from, state) do
    ets_key = {user_id, project_id, agent_id, skill.name}
    root_path = DetsManager.root_path_for(user_id, project_id)

    if root_path do
      case ensure_dets_and_insert(root_path, ets_key, skill) do
        :ok ->
          :ets.insert(state.ets_table, {ets_key, skill})
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      Logger.warning("ProceduralMemory: no root_path for project #{project_id}, ETS-only save")
      :ets.insert(state.ets_table, {ets_key, skill})
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call({:delete, user_id, project_id, agent_id, skill_name}, _from, state) do
    ets_key = {user_id, project_id, agent_id, skill_name}
    root_path = DetsManager.root_path_for(user_id, project_id)

    if root_path do
      case resolve_dets(root_path) do
        {:ok, dets_ref} -> :dets.delete(dets_ref, ets_key)
        _ -> :ok
      end
    end

    :ets.delete(state.ets_table, ets_key)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:delete_all, user_id, project_id, agent_id}, _from, state) do
    pattern = {{user_id, project_id, agent_id, :_}, :_}
    keys = :ets.match_object(state.ets_table, pattern) |> Enum.map(fn {k, _} -> k end)

    delete_keys(state, keys, user_id, project_id)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_call({:delete_by_project, user_id, project_id}, _from, state) do
    pattern = {{user_id, project_id, :_, :_}, :_}
    keys = :ets.match_object(state.ets_table, pattern) |> Enum.map(fn {k, _} -> k end)

    delete_keys(state, keys, user_id, project_id)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_call({:hydrate_project, root_path}, _from, state) do
    case DetsManager.open(root_path, @store_name) do
      {:ok, dets_ref} ->
        count =
          :dets.foldl(
            fn {key, value}, acc ->
              :ets.insert(state.ets_table, {key, value})
              acc + 1
            end,
            0,
            dets_ref
          )

        Logger.info("ProceduralMemory: hydrated #{count} skills for #{root_path}")
        {:reply, {:ok, count}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:evict_project, user_id, project_id}, _from, state) do
    pattern = {{user_id, project_id, :_, :_}, :_}
    keys = :ets.match_object(state.ets_table, pattern) |> Enum.map(fn {k, _} -> k end)

    Enum.each(keys, fn key -> :ets.delete(state.ets_table, key) end)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    sync_all_projects(state.ets_table)
    schedule_sync(state.sync_interval)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    sync_all_projects(state.ets_table)
    :ok
  end

  # --- Private helpers ---

  defp format_skills(skills) do
    Enum.map_join(skills, "\n\n", fn skill ->
      confidence_pct = round(skill.confidence * 100)

      parts =
        [
          "### #{skill.name} (#{confidence_pct}% confidence, used #{skill.success_count + skill.failure_count} times)"
        ]

      parts = parts ++ ["Domain: #{skill.domain}", "Strategy: #{skill.strategy}"]

      parts =
        if skill.tool_patterns != [],
          do: parts ++ ["Tools: #{Enum.join(skill.tool_patterns, " -> ")}"],
          else: parts

      parts =
        if skill.error_patterns != [],
          do: parts ++ ["Error recovery: #{Enum.join(skill.error_patterns, "; ")}"],
          else: parts

      Enum.join(parts, "\n")
    end)
  end

  defp ensure_dets_and_insert(root_path, key, value) do
    case resolve_dets(root_path) do
      {:ok, dets_ref} -> :dets.insert(dets_ref, {key, value})
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_dets(root_path) do
    case DetsManager.lookup(root_path, @store_name) do
      nil -> DetsManager.open(root_path, @store_name)
      dets_ref -> {:ok, dets_ref}
    end
  end

  defp delete_keys(state, keys, user_id, project_id) do
    root_path = DetsManager.root_path_for(user_id, project_id)

    dets_ref =
      if root_path do
        case resolve_dets(root_path) do
          {:ok, ref} -> ref
          _ -> nil
        end
      end

    Enum.each(keys, fn key ->
      if dets_ref, do: :dets.delete(dets_ref, key)
      :ets.delete(state.ets_table, key)
    end)
  end

  defp sync_all_projects(ets_table) do
    all_projects = DetsManager.registered_projects()
    root_to_keys = build_root_to_keys(all_projects)

    all_projects
    |> Enum.map(fn {_, root_path} -> root_path end)
    |> Enum.uniq()
    |> Enum.each(fn root_path ->
      sync_project(ets_table, root_path, root_to_keys[root_path] || MapSet.new())
    end)
  end

  defp sync_project(ets_table, root_path, project_keys) do
    case DetsManager.lookup(root_path, @store_name) do
      nil -> :ok
      dets_ref -> sync_ets_to_dets(ets_table, dets_ref, project_keys)
    end
  end

  defp sync_ets_to_dets(ets_table, dets_ref, project_keys) do
    :ets.foldl(
      fn {{u, p, _, _} = key, value}, :ok ->
        if MapSet.member?(project_keys, {u, p}), do: :dets.insert(dets_ref, {key, value})
        :ok
      end,
      :ok,
      ets_table
    )

    :dets.sync(dets_ref)
  end

  defp build_root_to_keys(projects) do
    Enum.group_by(projects, fn {_, rp} -> rp end, fn {key, _} -> key end)
    |> Map.new(fn {rp, keys} -> {rp, MapSet.new(keys)} end)
  end

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
