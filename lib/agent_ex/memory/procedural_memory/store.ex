defmodule AgentEx.Memory.ProceduralMemory.Store do
  @moduledoc """
  Tier 4: Procedural memory (learned skills) using ETS + DETS.

  Stores `Skill` structs keyed by `{user_id, project_id, agent_id, skill_name}`.
  Skills capture reusable strategies, tool patterns, and error recovery approaches
  that agents learn from session reflections.
  """

  use GenServer

  @behaviour AgentEx.Memory.Tier

  alias AgentEx.Memory.ProceduralMemory.{Loader, Skill}

  require Logger

  defstruct [:ets_table, :dets_table, :sync_interval]

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
    case :ets.lookup(:procedural_memory, {user_id, project_id, agent_id, skill_name}) do
      [{_key, skill}] -> {:ok, skill}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "Return all skills for `(user_id, project_id, agent_id)`."
  def all(user_id, project_id, agent_id) do
    :ets.foldl(
      fn
        {{^user_id, ^project_id, ^agent_id, _}, skill}, acc -> [skill | acc]
        _, acc -> acc
      end,
      [],
      :procedural_memory
    )
  rescue
    ArgumentError -> []
  end

  @doc "Return skills matching a domain."
  def get_by_domain(user_id, project_id, agent_id, domain) do
    :ets.foldl(
      fn
        {{^user_id, ^project_id, ^agent_id, _}, skill}, acc ->
          if skill.domain == domain, do: [skill | acc], else: acc

        _, acc ->
          acc
      end,
      [],
      :procedural_memory
    )
  rescue
    ArgumentError -> []
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
      Application.get_env(:agent_ex, :procedural_memory_sync_interval, :timer.seconds(30))

    dets_dir = Application.get_env(:agent_ex, :dets_dir, "priv/data")
    File.mkdir_p!(dets_dir)
    dets_path = Path.join(dets_dir, "procedural_memory.dets") |> String.to_charlist()

    {:ok, dets_table} = :dets.open_file(:procedural_memory_dets, file: dets_path, type: :set)

    ets_table =
      :ets.new(:procedural_memory, [:set, :named_table, :public, read_concurrency: true])

    Loader.hydrate(ets_table, dets_table)
    schedule_sync(sync_interval)

    state = %__MODULE__{
      ets_table: ets_table,
      dets_table: dets_table,
      sync_interval: sync_interval
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:put, user_id, project_id, agent_id, %Skill{} = skill}, _from, state) do
    ets_key = {user_id, project_id, agent_id, skill.name}

    case :dets.insert(state.dets_table, {ets_key, skill}) do
      :ok ->
        :ets.insert(state.ets_table, {ets_key, skill})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete, user_id, project_id, agent_id, skill_name}, _from, state) do
    ets_key = {user_id, project_id, agent_id, skill_name}

    case :dets.delete(state.dets_table, ets_key) do
      :ok ->
        :ets.delete(state.ets_table, ets_key)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:delete_all, user_id, project_id, agent_id}, _from, state) do
    keys =
      :ets.foldl(
        fn
          {{^user_id, ^project_id, ^agent_id, _} = k, _}, acc -> [k | acc]
          _, acc -> acc
        end,
        [],
        state.ets_table
      )

    delete_keys(state, keys)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_call({:delete_by_project, user_id, project_id}, _from, state) do
    keys =
      :ets.foldl(
        fn
          {{^user_id, ^project_id, _, _} = k, _}, acc -> [k | acc]
          _, acc -> acc
        end,
        [],
        state.ets_table
      )

    delete_keys(state, keys)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    Loader.sync(state.ets_table, state.dets_table)
    schedule_sync(state.sync_interval)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Loader.sync(state.ets_table, state.dets_table)
    :dets.close(state.dets_table)
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

  defp delete_keys(state, keys) do
    Enum.each(keys, fn key ->
      case :dets.delete(state.dets_table, key) do
        :ok ->
          :ets.delete(state.ets_table, key)

        {:error, reason} ->
          Logger.warning(
            "ProceduralMemory: DETS delete failed for #{inspect(key)}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
