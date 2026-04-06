defmodule AgentEx.Defaults.Tools do
  @moduledoc """
  Code-defined default HTTP tool templates.

  Each template is a map of HttpTool fields (without user_id, project_id, id,
  or timestamps — those are filled at seed time). Add new default tools by
  appending to `@templates`.
  """

  @templates []

  @doc "Returns the list of default HTTP tool templates."
  def templates, do: @templates

  @doc "Returns just the names of default tools."
  def names, do: Enum.map(@templates, & &1.name)
end
