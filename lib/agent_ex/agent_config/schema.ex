defmodule AgentEx.AgentConfig.Schema do
  @moduledoc """
  Ecto schema for agent_configs table.
  Maps to/from AgentConfig struct for persistence.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "agent_configs" do
    belongs_to(:project, AgentEx.Projects.Project)
    field(:user_id, :integer)
    field(:name, :string)
    field(:description, :string)
    field(:system, :boolean, default: false)

    # Identity
    field(:role, :string)
    field(:expertise, {:array, :string}, default: [])
    field(:personality, :string)

    # Goal
    field(:goal, :string)
    field(:success_criteria, :string)

    # Constraints
    field(:constraints, {:array, :string}, default: [])
    field(:scope, :string)

    # Tools
    field(:tool_ids, {:array, :string}, default: [])
    field(:tool_guidance, :string)
    field(:tool_examples, {:array, :map}, default: [])
    field(:disabled_builtins, {:array, :string}, default: [])

    # Output
    field(:output_format, :string)
    field(:system_prompt, :string)

    # Provider/Model
    field(:provider, :string, default: "openai")
    field(:model, :string, default: "gpt-4o-mini")
    field(:context_window, :integer)

    # Safety
    field(:intervention_pipeline, {:array, :map}, default: [])
    field(:sandbox, :map, default: %{})
    field(:execution_mode, :string, default: "interactive")
    field(:budget, :map, default: %{})

    # Capability index
    field(:capability_embedding, Pgvector.Ecto.Vector)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :name]
  @optional_fields [
    :user_id,
    :project_id,
    :description,
    :system,
    :role,
    :expertise,
    :personality,
    :goal,
    :success_criteria,
    :constraints,
    :scope,
    :tool_ids,
    :tool_guidance,
    :tool_examples,
    :disabled_builtins,
    :output_format,
    :system_prompt,
    :provider,
    :model,
    :context_window,
    :intervention_pipeline,
    :sandbox,
    :execution_mode,
    :budget,
    :capability_embedding
  ]

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:project_id, :name])
    |> foreign_key_constraint(:project_id)
  end

  @doc "Convert an AgentConfig struct to Ecto-compatible attrs map."
  def from_config(%AgentEx.AgentConfig{} = config) do
    config
    |> Map.from_struct()
    |> Map.put(:execution_mode, to_string(config.execution_mode))
  end

  @doc "Convert an Ecto schema row to an AgentConfig struct."
  def to_config(%__MODULE__{} = row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__, :project, :capability_embedding, :system])
    |> Map.update(:execution_mode, :interactive, &coerce_execution_mode/1)
    |> then(&struct!(AgentEx.AgentConfig, &1))
  end

  defp coerce_execution_mode("autonomous"), do: :autonomous
  defp coerce_execution_mode("interactive"), do: :interactive
  defp coerce_execution_mode(atom) when is_atom(atom), do: atom
  defp coerce_execution_mode(_), do: :interactive
end
