defmodule AgentEx.Memory.ProceduralMemory.Observer do
  @moduledoc """
  Lightweight observation recorder. No GenServer — writes directly to Tier 2.

  Records tool execution outcomes per session for later Reflector analysis.
  Observations are stored as `PersistentMemory.Store` entries with type
  `"procedural_observation"` and cleaned up after the Reflector processes them.
  """

  alias AgentEx.Memory.PersistentMemory.Store, as: Tier2

  @observation_type "procedural_observation"
  @max_observations_per_session 200

  @doc """
  Record a batch of tool observations from a sensing phase.

  Each observation is stored as a Tier 2 entry keyed by
  `"proc_obs:<session_id>:<tool_name>:<usec_timestamp>"`.
  """
  def record_observations(user_id, project_id, agent_id, session_id, observations, iteration) do
    count = observation_count(user_id, project_id, agent_id, session_id)
    remaining = max(@max_observations_per_session - count, 0)

    if remaining == 0 do
      :ok
    else
      observations
      |> Enum.take(remaining)
      |> Enum.each(fn obs ->
        usec = System.unique_integer([:positive])
        key = "proc_obs:#{session_id}:#{obs.name}:#{usec}"

        value = %{
          "session_id" => session_id,
          "tool_name" => obs.name,
          "call_id" => obs.call_id,
          "success" => !obs.is_error,
          "content_preview" => String.slice(obs.content, 0, 200),
          "iteration" => iteration,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Tier2.put(user_id, project_id, agent_id, key, value, @observation_type)
      end)
    end
  end

  @doc "Retrieve all observations for a session from Tier 2."
  def get_observations(user_id, project_id, agent_id, session_id) do
    user_id
    |> Tier2.get_by_type(project_id, agent_id, @observation_type)
    |> Enum.filter(fn entry -> entry.value["session_id"] == session_id end)
    |> Enum.sort_by(fn entry -> entry.value["timestamp"] end)
  end

  @doc "Clear observations for a session from Tier 2."
  def clear_observations(user_id, project_id, agent_id, session_id) do
    user_id
    |> get_observations(project_id, agent_id, session_id)
    |> Enum.each(fn entry ->
      Tier2.delete(user_id, project_id, agent_id, entry.key)
    end)
  end

  defp observation_count(user_id, project_id, agent_id, session_id) do
    user_id
    |> Tier2.get_by_type(project_id, agent_id, @observation_type)
    |> Enum.count(fn entry -> entry.value["session_id"] == session_id end)
  end
end
