defmodule AgentEx.Memory.ProceduralMemory.Reflector do
  @moduledoc """
  On session close, analyzes tool observations via LLM to extract or update
  procedural skills. Follows the same LLM-calling pattern as `Promotion`.
  """

  alias AgentEx.Memory.ProceduralMemory.{Observer, Skill, Store}
  alias AgentEx.{Message, ModelClient}

  require Logger

  @reflection_system_prompt """
  You are a skill extraction engine. Given tool execution observations from an agent session,
  extract reusable skills and strategies.

  For each skill, output a JSON array of objects with these fields:
  - "name": short skill name (snake_case, e.g. "web_research_with_fallback")
  - "domain": category (e.g. "research", "code_generation", "data_analysis", "system_ops")
  - "description": one-line description of what the skill accomplishes
  - "strategy": step-by-step strategy (2-4 sentences)
  - "tool_patterns": ordered list of tool names used (e.g. ["web_search", "web_fetch"])
  - "error_patterns": list of error recovery strategies observed (e.g. ["retry with different query on 404"])
  - "outcome": "success" or "failure"

  Focus on:
  - Tool combination patterns that worked
  - Error recovery strategies
  - Sequential workflows (tool A -> tool B -> tool C)
  - What made this approach succeed or fail

  If no meaningful skills can be extracted, return an empty JSON array: []
  Output ONLY a valid JSON array. No markdown, no explanation.
  """

  @doc """
  Reflect on a session's observations and extract/update skills.

  Called from Promotion after `close_session_with_summary`.
  """
  @spec reflect(term(), term(), String.t(), String.t(), ModelClient.t(), keyword()) ::
          {:ok, [Skill.t()]} | {:error, term()}
  def reflect(user_id, project_id, agent_id, session_id, model_client, _opts \\ []) do
    observations = Observer.get_observations(user_id, project_id, agent_id, session_id)

    if observations == [] do
      {:ok, []}
    else
      transcript = format_observations(observations)

      messages = [
        Message.system(@reflection_system_prompt),
        Message.user("Extract skills from these tool observations:\n\n#{transcript}")
      ]

      case ModelClient.create(model_client, messages) do
        {:ok, %Message{content: content}} ->
          skills = extract_and_upsert(content, user_id, project_id, agent_id)
          Observer.clear_observations(user_id, project_id, agent_id, session_id)
          {:ok, skills}

        {:error, reason} ->
          Logger.warning("ProceduralMemory Reflector failed: #{inspect(reason)}")
          {:error, {:reflection_failed, reason}}
      end
    end
  end

  defp format_observations(observations) do
    observations
    |> Enum.group_by(fn entry -> entry.value["iteration"] end)
    |> Enum.sort_by(fn {iteration, _} -> iteration end)
    |> Enum.map_join("\n\n", fn {iteration, entries} ->
      lines = Enum.map_join(entries, "\n", &format_observation/1)
      "Iteration #{iteration}:\n#{lines}"
    end)
  end

  defp format_observation(entry) do
    v = entry.value
    status = if v["success"], do: "OK", else: "ERROR"
    "  - [#{status}] #{v["tool_name"]}: #{v["content_preview"]}"
  end

  defp extract_and_upsert(content, user_id, project_id, agent_id) do
    case parse_skills_response(content) do
      {:ok, skill_maps} ->
        Enum.map(skill_maps, fn skill_map ->
          upsert_skill(user_id, project_id, agent_id, skill_map)
        end)

      {:error, reason} ->
        Logger.warning("ProceduralMemory: failed to parse skills JSON: #{inspect(reason)}")
        []
    end
  end

  defp parse_skills_response(content) do
    # Strip markdown fences if present
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```json\s*/i, "")
      |> String.replace(~r/```\s*$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) ->
        {:ok, Enum.filter(list, &valid_skill_map?/1)}

      {:ok, _} ->
        {:error, :not_a_list}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_skill_map?(item) do
    is_map(item) and is_binary(item["name"]) and is_binary(item["strategy"]) and
      (is_nil(item["tool_patterns"]) or is_list(item["tool_patterns"])) and
      (is_nil(item["error_patterns"]) or is_list(item["error_patterns"]))
  end

  defp upsert_skill(user_id, project_id, agent_id, skill_map) do
    name = skill_map["name"]
    signal = if skill_map["outcome"] == "success", do: 1.0, else: 0.0

    case Store.get(user_id, project_id, agent_id, name) do
      {:ok, existing} ->
        updated =
          existing
          |> Skill.update_confidence(signal)
          |> merge_skill_data(skill_map)

        Store.put(user_id, project_id, agent_id, updated)
        updated

      :not_found ->
        skill =
          Skill.new(%{
            name: name,
            domain: skill_map["domain"] || "general",
            description: skill_map["description"] || name,
            strategy: skill_map["strategy"],
            tool_patterns: skill_map["tool_patterns"] || [],
            error_patterns: skill_map["error_patterns"] || [],
            confidence: if(signal >= 0.5, do: 0.6, else: 0.4)
          })

        Store.put(user_id, project_id, agent_id, skill)
        skill
    end
  end

  defp merge_skill_data(%Skill{} = skill, skill_map) do
    # Merge new tool/error patterns without duplicating
    new_tools = Enum.uniq(skill.tool_patterns ++ List.wrap(skill_map["tool_patterns"]))
    new_errors = Enum.uniq(skill.error_patterns ++ List.wrap(skill_map["error_patterns"]))

    # Update strategy if the new one is longer/better (heuristic: prefer longer)
    new_strategy = skill_map["strategy"] || ""

    strategy =
      if String.length(new_strategy) > String.length(skill.strategy),
        do: new_strategy,
        else: skill.strategy

    %{skill | tool_patterns: new_tools, error_patterns: new_errors, strategy: strategy}
  end
end
