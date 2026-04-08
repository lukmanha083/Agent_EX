defmodule AgentEx.HttpToolStore do
  @moduledoc """
  Postgres-backed persistence for HTTP tool configs.
  Same pattern as AgentStore — Ecto queries, no GenServer/ETS/DETS.
  """

  import Ecto.Query

  alias AgentEx.HttpTool
  alias AgentEx.HttpTool.Schema
  alias AgentEx.Repo

  require Logger

  @doc "Save an HTTP tool config (insert or update)."
  def save(%HttpTool{} = config) do
    attrs = Schema.from_tool(config)

    %Schema{}
    |> Schema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, row} -> {:ok, Schema.to_tool(row)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Get a specific HTTP tool config."
  def get(user_id, project_id, tool_id) do
    case Repo.get_by(Schema, id: tool_id, user_id: user_id, project_id: project_id) do
      nil -> :not_found
      row -> {:ok, Schema.to_tool(row)}
    end
  end

  @doc "List all HTTP tool configs for a user within a project."
  def list(user_id, project_id) do
    from(t in Schema,
      where: t.user_id == ^user_id and t.project_id == ^project_id and t.system == false,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(&Schema.to_tool/1)
  end

  @doc "Delete an HTTP tool config."
  def delete(user_id, project_id, tool_id) do
    case Repo.get_by(Schema, id: tool_id, user_id: user_id, project_id: project_id) do
      nil ->
        :ok

      row ->
        case Repo.delete(row) do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  # --- Backward-compatible no-ops ---

  @doc "No-op. Previously hydrated DETS → ETS."
  def hydrate_project(_root_path), do: {:ok, 0}

  @doc "No-op. Previously evicted ETS entries."
  def evict_project(_user_id, _project_id), do: {:ok, 0}
end
