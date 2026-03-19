defmodule AgentEx.Memory.Promotion do
  @moduledoc """
  Memory promotion mechanisms that populate Tier 3 semantic memory.

  Two promotion paths:
  1. **Session summary** — on session close, LLM summarizes the conversation
     into key facts, which are embedded and stored in Tier 3.
  2. **save_memory tool** — a tool factory that lets agents save facts to
     Tier 3 mid-conversation for retrieval in future sessions.

  ## The cycle

      Session N:
        Agent works → saves facts (save_memory tool) → Tier 3
        Session closes → LLM summarizes → summary stored in Tier 3

      Session N+1:
        Session starts → ContextBuilder queries Tier 3
        → "## Relevant Past Context"
        → LLM sees past facts + summaries
        → makes better decisions informed by history
  """

  alias AgentEx.{Memory, Message, ModelClient, Tool}

  require Logger

  @summary_system_prompt """
  You are a memory summarizer. Given a conversation transcript, extract the key facts,
  decisions, outcomes, and insights worth remembering for future sessions.

  Output a concise bulleted list of facts. Focus on:
  - What was accomplished
  - Key decisions and their rationale
  - Important facts learned
  - User preferences discovered
  - Errors encountered and how they were resolved

  Be concise — each fact should be one line. Omit greetings, pleasantries, and filler.
  """

  @doc """
  Close a session and promote a summary to Tier 3.

  1. Retrieves all Tier 1 messages
  2. LLM summarizes into key facts
  3. Stores summary in Tier 3 (embedded as vector)
  4. Stops the Tier 1 session

  ## Options
  - `:max_messages` — max messages to include in summary (default: 50)
  """
  @spec close_session_with_summary(String.t(), String.t(), ModelClient.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def close_session_with_summary(agent_id, session_id, model_client, opts \\ []) do
    max_messages = Keyword.get(opts, :max_messages, 50)

    messages = Memory.get_messages(agent_id, session_id)

    if messages == [] do
      Memory.stop_session(agent_id, session_id)
      {:ok, ""}
    else
      transcript =
        messages
        |> Enum.take(-max_messages)
        |> Enum.map_join("\n", fn msg ->
          "#{msg.role}: #{msg.content}"
        end)

      summary_messages = [
        Message.system(@summary_system_prompt),
        Message.user("Summarize this conversation:\n\n#{transcript}")
      ]

      result =
        with {:ok, %Message{content: summary}} when is_binary(summary) and summary != "" <-
               ModelClient.create(model_client, summary_messages),
             {:ok, _} <-
               Memory.store_memory(
                 agent_id,
                 "Session summary (#{session_id}):\n#{summary}",
                 "session_summary",
                 session_id
               ) do
          Logger.info("Promotion: summarized session #{session_id} for agent #{agent_id}")
          {:ok, summary}
        else
          {:ok, %Message{}} ->
            {:error, :empty_summary}

          {:error, reason} ->
            {:error, {:summary_failed, reason}}
        end

      Memory.stop_session(agent_id, session_id)
      result
    end
  end

  @doc """
  Build a save_memory tool for an agent.

  When the LLM calls this tool, the fact is embedded and stored in Tier 3
  for retrieval in future sessions via ContextBuilder.

  ## Options
  - `:agent_id` — the agent's ID (required)
  """
  @spec save_memory_tool(keyword()) :: Tool.t()
  def save_memory_tool(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    Tool.new(
      name: "save_memory",
      description:
        "Save an important fact or insight to long-term memory. " <>
          "Use this to remember things that would be useful in future sessions, " <>
          "such as user preferences, successful strategies, or key decisions.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "fact" => %{
            "type" => "string",
            "description" => "The fact or insight to remember"
          },
          "category" => %{
            "type" => "string",
            "description" => "Category: preference, decision, insight, outcome, or fact",
            "enum" => ["preference", "decision", "insight", "outcome", "fact"]
          }
        },
        "required" => ["fact"]
      },
      kind: :write,
      function: fn args ->
        fact = Map.fetch!(args, "fact")
        category = Map.get(args, "category", "fact")

        case Memory.store_memory(agent_id, fact, category) do
          {:ok, _} ->
            Logger.debug(
              "Promotion: agent #{agent_id} saved memory: #{String.slice(fact, 0, 50)}"
            )

            {:ok, "Saved to long-term memory: #{fact}"}

          {:error, reason} ->
            {:error, "Failed to save memory: #{inspect(reason)}"}
        end
      end
    )
  end
end
