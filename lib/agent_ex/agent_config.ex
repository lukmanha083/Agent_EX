defmodule AgentEx.AgentConfig do
  @moduledoc """
  Agent definition struct — stores everything needed to instantiate a
  specialized agent: identity, goals, constraints, tool guidance, knowledge,
  output format, few-shot examples, memory config, and intervention rules.

  Context assembly order (injected into LLM context window by ContextBuilder):
  1. Identity (role + expertise + personality → system message)
  2. Goal + success criteria
  3. Constraints + scope
  4. Tool guidance (when/how to use tools)
  5. Knowledge sources (RAG-retrieved, per-agent)
  6. Memory context (Tier 2/3 from ContextBuilder)
  7. Few-shot examples (tool call demonstrations)
  8. Output format (response structure template)
  9. System prompt (additional free-form instructions)
  10. Conversation history
  """

  @enforce_keys [:id, :user_id, :project_id, :name]
  defstruct [
    :id,
    :user_id,
    :project_id,
    :name,
    :description,

    # -- Identity --
    role: nil,
    expertise: [],
    personality: nil,

    # -- Goal --
    goal: nil,
    success_criteria: nil,

    # -- Constraints --
    constraints: [],
    scope: nil,

    # -- Tool guidance --
    tool_ids: [],
    tool_guidance: nil,
    tool_examples: [],

    # -- Output --
    output_format: nil,

    # -- Free-form system prompt (appended after structured fields) --
    system_prompt: nil,

    # -- Provider/Model --
    provider: "openai",
    model: "gpt-4o-mini",
    context_window: nil,
    disabled_builtins: [],

    # -- Safety --
    intervention_pipeline: [],
    sandbox: %{},
    execution_mode: :interactive,
    budget: %{},

    # -- Timestamps --
    inserted_at: nil,
    updated_at: nil
  ]

  @type handler_entry :: %{
          required(:id) => String.t(),
          optional(:allowed_writes) => [String.t()]
        }

  @type sandbox :: %{
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
          project_id: integer(),
          name: String.t(),
          description: String.t() | nil,
          role: String.t() | nil,
          expertise: [String.t()],
          personality: String.t() | nil,
          goal: String.t() | nil,
          success_criteria: String.t() | nil,
          constraints: [String.t()],
          scope: String.t() | nil,
          tool_ids: [String.t()],
          tool_guidance: String.t() | nil,
          tool_examples: [map()],
          output_format: String.t() | nil,
          system_prompt: String.t() | nil,
          provider: String.t(),
          model: String.t(),
          context_window: pos_integer() | nil,
          disabled_builtins: [String.t()],
          intervention_pipeline: [handler_entry()],
          sandbox: sandbox(),
          execution_mode: execution_mode(),
          budget: budget(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # provider and model are intentionally excluded — they are immutable after creation
  @updatable_fields [
    :name,
    :description,
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
    :output_format,
    :system_prompt,
    :context_window,
    :disabled_builtins,
    :intervention_pipeline,
    :sandbox,
    :execution_mode,
    :budget,
    :project_id
  ]

  @defaults %{
    provider: "openai",
    model: "gpt-4o-mini",
    tool_ids: [],
    disabled_builtins: [],
    expertise: [],
    constraints: [],
    tool_examples: [],
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

  @doc """
  Import an agent config from an external JSON map (e.g., kidkazz distill output).

  Strips keys prefixed with `_` (like `_distill_metadata`), converts string keys
  to atoms, handles `execution_mode` string→atom conversion, and injects the
  required `user_id` and `project_id`.

  ## Example

      json = File.read!("agent.json") |> Jason.decode!()
      config = AgentConfig.from_map(json, user_id: 1, project_id: 1)
  """
  # String versions of known fields — used to filter BEFORE atomizing
  # (prevents atom table exhaustion from arbitrary JSON keys)
  # Excluded: "id", "inserted_at", "updated_at" — always generated locally by new/1
  @known_field_strings MapSet.new([
                         "user_id",
                         "project_id",
                         "name",
                         "description",
                         "role",
                         "expertise",
                         "personality",
                         "goal",
                         "success_criteria",
                         "constraints",
                         "scope",
                         "tool_ids",
                         "tool_guidance",
                         "tool_examples",
                         "output_format",
                         "system_prompt",
                         "provider",
                         "model",
                         "context_window",
                         "disabled_builtins",
                         "intervention_pipeline",
                         "sandbox",
                         "execution_mode",
                         "budget"
                       ])

  def from_map(attrs, opts) when is_map(attrs) and is_list(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    project_id = Keyword.fetch!(opts, :project_id)

    name = attrs["name"]

    if !is_binary(name) or String.trim(name) == "" do
      raise ArgumentError, ~s(imported JSON must include a non-empty "name" field)
    end

    # Filter on string keys first (safe), then atomize only known fields
    atom_attrs =
      attrs
      |> Enum.reject(fn {k, _v} -> String.starts_with?(to_string(k), "_") end)
      |> Enum.filter(fn {k, _v} -> MapSet.member?(@known_field_strings, to_string(k)) end)
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(to_string(k)), v} end)
      |> Map.new()
      |> Map.put(:user_id, user_id)
      |> Map.put(:project_id, project_id)
      |> coerce_execution_mode()
      |> normalize_composite_fields()

    new(atom_attrs)
  end

  defp coerce_execution_mode(%{execution_mode: mode} = attrs) when is_binary(mode) do
    atom_mode =
      case mode do
        "interactive" -> :interactive
        "autonomous" -> :autonomous
        _ -> :interactive
      end

    %{attrs | execution_mode: atom_mode}
  end

  defp coerce_execution_mode(attrs), do: attrs

  defp normalize_composite_fields(attrs) do
    attrs
    |> coerce_list(:expertise)
    |> coerce_list(:constraints)
    |> coerce_list(:tool_ids)
    |> coerce_list(:tool_examples)
    |> coerce_list(:disabled_builtins)
    |> coerce_list(:intervention_pipeline)
    |> coerce_map(:sandbox)
    |> coerce_map(:budget)
  end

  defp coerce_list(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, val} when is_list(val) -> attrs
      {:ok, val} when is_binary(val) and val != "" -> Map.put(attrs, key, [val])
      {:ok, _} -> Map.put(attrs, key, [])
      :error -> attrs
    end
  end

  defp coerce_map(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, val} when is_map(val) -> attrs
      {:ok, _} -> Map.put(attrs, key, %{})
      :error -> attrs
    end
  end

  @doc "Update an existing agent config, bumping the updated_at timestamp."
  def update(%__MODULE__{} = config, attrs) when is_map(attrs) do
    config
    |> Map.merge(Map.take(attrs, @updatable_fields))
    |> Map.put(:updated_at, DateTime.utc_now())
  end

  def update(%__MODULE__{} = config, attrs) when is_list(attrs) do
    update(config, Map.new(attrs))
  end

  @doc """
  Build the full system message from structured fields.
  This is what gets injected as the first system message(s) in the context window.
  ContextBuilder appends memory context after this.
  """
  def build_system_messages(%__MODULE__{} = config) do
    sections =
      [
        build_identity(config),
        build_goal(config),
        build_constraints(config),
        build_tool_guidance(config),
        build_output_format(config),
        build_system_prompt(config)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_identity(%{role: nil, personality: nil, expertise: expertise})
       when expertise in [nil, []],
       do: nil

  defp build_identity(config) do
    expertise = config.expertise || []
    parts = []
    parts = if config.role, do: parts ++ ["You are #{config.role}."], else: parts

    parts =
      if expertise != [] do
        parts ++ ["Your expertise: #{Enum.join(expertise, ", ")}."]
      else
        parts
      end

    parts =
      if config.personality do
        parts ++ ["Communication style: #{config.personality}."]
      else
        parts
      end

    if parts == [], do: nil, else: Enum.join(parts, " ")
  end

  defp build_goal(%{goal: nil}), do: nil

  defp build_goal(config) do
    parts = ["## Goal\n#{config.goal}"]

    parts =
      if config.success_criteria do
        parts ++ ["Success criteria: #{config.success_criteria}"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  defp build_constraints(%{constraints: constraints, scope: nil})
       when constraints in [nil, []],
       do: nil

  defp build_constraints(config) do
    constraints = config.constraints || []
    parts = []

    parts =
      if constraints != [] do
        rules = Enum.map_join(constraints, "\n", &"- #{&1}")
        parts ++ ["## Constraints\n#{rules}"]
      else
        parts
      end

    parts =
      if config.scope do
        parts ++ ["Scope: #{config.scope}"]
      else
        parts
      end

    if parts == [], do: nil, else: Enum.join(parts, "\n")
  end

  defp build_tool_guidance(%{tool_guidance: nil}), do: nil
  defp build_tool_guidance(%{tool_guidance: g}), do: "## Tool Usage\n#{g}"

  defp build_output_format(%{output_format: nil}), do: nil
  defp build_output_format(%{output_format: f}), do: "## Output Format\n#{f}"

  defp build_system_prompt(%{system_prompt: nil}), do: nil
  defp build_system_prompt(%{system_prompt: ""}), do: nil
  defp build_system_prompt(%{system_prompt: p}), do: p

  defp generate_id do
    "agent-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
  end
end
