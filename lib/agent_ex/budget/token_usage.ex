defmodule AgentEx.Budget.TokenUsage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "project_token_usage" do
    belongs_to(:project, AgentEx.Projects.Project)
    belongs_to(:conversation, AgentEx.Chat.Conversation)

    field(:provider, :string)
    field(:model, :string)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [
      :project_id,
      :conversation_id,
      :provider,
      :model,
      :input_tokens,
      :output_tokens
    ])
    |> validate_required([:project_id, :provider, :model])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:project_id)
  end
end
