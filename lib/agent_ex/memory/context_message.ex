defmodule AgentEx.Memory.ContextMessage do
  @moduledoc """
  A message in the LLM context window.
  Used by ContextBuilder to compose the final prompt.
  """

  @type t :: %__MODULE__{
          role: String.t(),
          content: String.t()
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content]

  def system(content), do: %__MODULE__{role: "system", content: content}
  def user(content), do: %__MODULE__{role: "user", content: content}
  def assistant(content), do: %__MODULE__{role: "assistant", content: content}
end
