defmodule AgentEx.Memory.ProceduralMemory.Skill do
  @moduledoc """
  A learned skill — captures a successful strategy for accomplishing a task.

  Stored in ETS/DETS via `ProceduralMemory.Store`. Confidence is updated
  via exponential moving average (EMA) after each session reflection.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          domain: String.t(),
          description: String.t(),
          strategy: String.t(),
          tool_patterns: [String.t()],
          error_patterns: [String.t()],
          confidence: float(),
          success_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          examples: [map()],
          last_used: DateTime.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:id, :name, :domain, :description, :strategy]
  defstruct [
    :id,
    :name,
    :domain,
    :description,
    :strategy,
    :last_used,
    :created_at,
    :updated_at,
    tool_patterns: [],
    error_patterns: [],
    confidence: 0.5,
    success_count: 0,
    failure_count: 0,
    examples: [],
    metadata: %{}
  ]

  @ema_decay 0.9
  @max_examples 5

  @doc "Create a new Skill from an attribute map."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    struct!(__MODULE__,
      id: Map.get(attrs, :id, generate_id()),
      name: Map.fetch!(attrs, :name),
      domain: Map.fetch!(attrs, :domain),
      description: Map.fetch!(attrs, :description),
      strategy: Map.fetch!(attrs, :strategy),
      tool_patterns: Map.get(attrs, :tool_patterns, []),
      error_patterns: Map.get(attrs, :error_patterns, []),
      confidence: Map.get(attrs, :confidence, 0.5),
      success_count: Map.get(attrs, :success_count, 0),
      failure_count: Map.get(attrs, :failure_count, 0),
      examples: Map.get(attrs, :examples, []),
      last_used: Map.get(attrs, :last_used),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now),
      metadata: Map.get(attrs, :metadata, %{})
    )
  end

  @doc """
  Update confidence via EMA. `signal` is 1.0 for success, 0.0 for failure.

  Formula: `new_confidence = old * 0.9 + signal * 0.1`
  """
  @spec update_confidence(t(), float()) :: t()
  def update_confidence(%__MODULE__{} = skill, signal)
      when is_float(signal) and signal >= 0.0 and signal <= 1.0 do
    new_confidence = skill.confidence * @ema_decay + signal * (1 - @ema_decay)

    {success_delta, failure_delta} =
      if signal >= 0.5, do: {1, 0}, else: {0, 1}

    %{
      skill
      | confidence: new_confidence,
        success_count: skill.success_count + success_delta,
        failure_count: skill.failure_count + failure_delta,
        last_used: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
    }
  end

  @doc "Add an example (capped at #{@max_examples} most recent)."
  @spec add_example(t(), map()) :: t()
  def add_example(%__MODULE__{} = skill, example) when is_map(example) do
    examples = Enum.take(skill.examples ++ [example], -@max_examples)
    %{skill | examples: examples, updated_at: DateTime.utc_now()}
  end

  defp generate_id do
    "skill-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
  end
end
