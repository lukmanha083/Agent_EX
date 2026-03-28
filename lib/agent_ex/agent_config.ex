defmodule AgentEx.AgentConfig do
  @moduledoc """
  Agent definition struct — stores everything needed to instantiate an agent:
  name, system prompt, provider/model, tools, memory config, and intervention rules.

  Maps to AutoGen's agent configuration but persisted for the UI-driven builder.
  """

  @enforce_keys [:id, :user_id, :name]
  defstruct [
    :id,
    :user_id,
    :name,
    :description,
    system_prompt: "You are a helpful AI assistant.",
    provider: "openai",
    model: "gpt-4o-mini",
    tool_ids: [],
    intervention_pipeline: [],
    sandbox: %{},
    execution_mode: :interactive,
    budget: %{},
    inserted_at: nil,
    updated_at: nil
  ]

  @type handler_entry :: %{
          required(:id) => String.t(),
          optional(:allowed_writes) => [String.t()]
        }

  @type sandbox :: %{
          optional(:root_path) => String.t(),
          optional(:disallowed_commands) => [String.t()]
        }

  @type execution_mode :: :interactive | :autonomous

  @type budget :: %{
          optional(:max_iterations) => pos_integer(),
          optional(:max_wall_time_s) => pos_integer(),
          optional(:max_cost_usd) => float()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: integer(),
          name: String.t(),
          description: String.t() | nil,
          system_prompt: String.t(),
          provider: String.t(),
          model: String.t(),
          tool_ids: [String.t()],
          intervention_pipeline: [handler_entry()],
          sandbox: sandbox(),
          execution_mode: execution_mode(),
          budget: budget(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @defaults %{
    system_prompt: "You are a helpful AI assistant.",
    provider: "openai",
    model: "gpt-4o-mini",
    tool_ids: [],
    intervention_pipeline: [],
    sandbox: %{},
    execution_mode: :interactive,
    budget: %{}
  }

  @doc "Create a new agent config with a generated ID and timestamps."
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    merged =
      @defaults
      |> Map.merge(attrs)
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:inserted_at, now)
      |> Map.put_new(:updated_at, now)

    struct!(__MODULE__, merged)
  end

  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  @doc "Update an existing agent config, bumping the updated_at timestamp."
  def update(%__MODULE__{} = config, attrs) when is_map(attrs) do
    config
    |> Map.merge(Map.take(attrs, [:name, :description, :system_prompt, :provider, :model, :tool_ids, :intervention_pipeline, :sandbox, :execution_mode, :budget]))
    |> Map.put(:updated_at, DateTime.utc_now())
  end

  def update(%__MODULE__{} = config, attrs) when is_list(attrs) do
    update(config, Map.new(attrs))
  end

  defp generate_id do
    "agent-#{System.unique_integer([:positive, :monotonic])}"
  end
end
