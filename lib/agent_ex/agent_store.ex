defmodule AgentEx.AgentStore do
  @moduledoc """
  Postgres-backed persistence for agent configs.
  Queries the `agent_configs` table via Ecto. No GenServer, ETS, or DETS —
  Postgres handles concurrency, durability, and cascading deletes.

  System agents (defaults) have `system: true` and are shared across projects.
  User agents have `system: false` and are scoped by `(user_id, project_id)`.
  """

  import Ecto.Query

  alias AgentEx.AgentConfig
  alias AgentEx.AgentConfig.Schema
  alias AgentEx.Repo

  require Logger

  @doc "Save an agent config (insert or update)."
  def save(%AgentConfig{} = config) do
    attrs = Schema.from_config(config)

    %Schema{}
    |> Schema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, row} -> {:ok, Schema.to_config(row)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Get a specific agent config by user_id, project_id, and agent_id."
  def get(user_id, project_id, agent_id) do
    case Repo.get_by(Schema, id: agent_id, user_id: user_id, project_id: project_id) do
      nil -> :not_found
      row -> {:ok, Schema.to_config(row)}
    end
  end

  @doc """
  List all agent configs for a user within a project.
  Returns user agents only (system agents merged at assembly time).
  """
  def list(user_id, project_id) do
    from(a in Schema,
      where: a.user_id == ^user_id and a.project_id == ^project_id and a.system == false,
      order_by: [desc: a.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(&Schema.to_config/1)
  end

  @doc "Delete an agent config."
  def delete(user_id, project_id, agent_id) do
    case Repo.get_by(Schema, id: agent_id, user_id: user_id, project_id: project_id) do
      nil ->
        :ok

      row ->
        case Repo.delete(row) do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc "List system (default) agents. Shared across all projects."
  def list_system do
    from(a in Schema, where: a.system == true, order_by: [asc: a.name])
    |> Repo.all()
    |> Enum.map(&Schema.to_config/1)
  end

  @doc """
  Save a system agent (upsert by name). Used at app boot to register defaults.
  System agents have nil project_id/user_id and system=true.
  Uses partial unique index `agent_configs_system_name_idx` for conflict detection.
  """
  def save_system(%AgentConfig{} = config) do
    attrs =
      config
      |> Map.put(:user_id, nil)
      |> Map.put(:project_id, nil)
      |> Schema.from_config()
      |> Map.put(:system, true)

    %Schema{}
    |> Schema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :name, :inserted_at]},
      conflict_target: {:unsafe_fragment, "name WHERE system = true"}
    )
  end

  # --- Backward-compatible no-ops (previously DETS lifecycle) ---

  @doc "No-op. Previously hydrated DETS → ETS. Postgres needs no hydration."
  def hydrate_project(_root_path), do: {:ok, 0}

  @doc "No-op. Previously evicted ETS entries. Postgres needs no eviction."
  def evict_project(_user_id, _project_id), do: {:ok, 0}
end
