defmodule AgentEx.CapabilityIndex do
  @moduledoc """
  Semantic search over agent and tool capabilities using pgvector.

  Embeds agent/tool descriptions on create/update and provides cosine
  similarity search so the orchestrator can select the most relevant
  specialists for a given task (meritocratic selection).

  At scale (100+ agents), the Planner only sees the top-k most relevant
  agents — not all of them.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias AgentEx.AgentConfig.Schema, as: AgentSchema
  alias AgentEx.HttpTool.Schema, as: ToolSchema
  alias AgentEx.Memory.Embeddings
  alias AgentEx.Repo

  require Logger

  @doc """
  Embed and store capability vector for an agent config.
  Builds a composite text from the agent's identity fields and embeds it.
  """
  def embed_agent(agent_id, project_id \\ nil) do
    case Repo.get(AgentSchema, agent_id) do
      nil ->
        {:error, :not_found}

      row ->
        text = build_agent_capability_text(row)

        case Embeddings.embed(text, project_id: project_id) do
          {:ok, vector} ->
            row
            |> AgentSchema.changeset(%{capability_embedding: vector})
            |> Repo.update()

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Embed and store capability vector for a tool config.
  """
  def embed_tool(tool_id, project_id \\ nil) do
    case Repo.get(ToolSchema, tool_id) do
      nil ->
        {:error, :not_found}

      row ->
        text = build_tool_capability_text(row)

        case Embeddings.embed(text, project_id: project_id) do
          {:ok, vector} ->
            row
            |> ToolSchema.changeset(%{capability_embedding: vector})
            |> Repo.update()

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Search for the most relevant agents for a given task.

  Searches both system agents and user agents for the project.
  Returns agents sorted by capability relevance (cosine similarity).
  """
  def search_agents(task_text, project_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)

    case Embeddings.embed(task_text, project_id: project_id) do
      {:ok, vector} ->
        results =
          from(a in AgentSchema,
            where:
              not is_nil(a.capability_embedding) and
                (a.system == true or a.project_id == ^project_id),
            order_by: cosine_distance(a.capability_embedding, ^vector),
            limit: ^limit,
            select: %{
              id: a.id,
              name: a.name,
              description: a.description,
              role: a.role,
              system: a.system,
              score: cosine_distance(a.capability_embedding, ^vector)
            }
          )
          |> Repo.all()

        {:ok, results}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Search for the most relevant tools for a given task.
  """
  def search_tools(task_text, project_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 15)

    case Embeddings.embed(task_text, project_id: project_id) do
      {:ok, vector} ->
        results =
          from(t in ToolSchema,
            where:
              not is_nil(t.capability_embedding) and
                (t.system == true or t.project_id == ^project_id),
            order_by: cosine_distance(t.capability_embedding, ^vector),
            limit: ^limit,
            select: %{
              id: t.id,
              name: t.name,
              description: t.description,
              kind: t.kind,
              system: t.system,
              score: cosine_distance(t.capability_embedding, ^vector)
            }
          )
          |> Repo.all()

        {:ok, results}

      {:error, _} = err ->
        err
    end
  end

  # --- Capability text builders ---

  defp build_agent_capability_text(row) do
    [
      row.name,
      row.description,
      row.role,
      if(is_list(row.expertise) and row.expertise != [],
        do: "expertise: #{Enum.join(row.expertise, ", ")}"
      ),
      row.goal,
      row.tool_guidance
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(". ")
  end

  defp build_tool_capability_text(row) do
    [
      row.name,
      row.description,
      if(row.method, do: "HTTP #{row.method}"),
      if(row.url_template, do: "URL: #{row.url_template}")
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(". ")
  end
end
