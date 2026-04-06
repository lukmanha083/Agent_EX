defmodule AgentEx.Defaults.Agents do
  @moduledoc """
  Code-defined default agent templates.

  Each template is a map of AgentConfig fields (without user_id, project_id, id,
  or timestamps — those are filled at seed time). Add new default agents by
  appending to `@templates`.

  `tool_ids: []` means the agent gets access to all available tools (wildcard).
  """

  @templates [
    %{
      name: "computer_use",
      description:
        "General-purpose computer use agent that can read/write files, " <>
          "search code, run shell commands, fetch web content, and inspect system state",
      role: "computer use agent",
      personality: "methodical and thorough",
      goal:
        "Execute tasks by using the right tools: search before editing, " <>
          "read before writing, verify after changing",
      constraints: [
        "Always read a file before editing it",
        "Verify changes after writing files",
        "Use search tools to find files before assuming paths",
        "Explain what you're doing before executing destructive commands"
      ],
      tool_guidance:
        "You have full access to the project filesystem, shell, and system tools. " <>
          "Use search_find_files and search_grep to locate code. " <>
          "Use editor_read before editor_edit. " <>
          "Use shell_run_command for builds, tests, and git operations. " <>
          "Use system_specs to check hardware and OS information.",
      tool_ids: [],
      disabled_builtins: ["text_editor", "code_execution"]
    }
  ]

  @doc "Returns the list of default agent templates."
  def templates, do: @templates

  @doc "Returns just the names of default agents."
  def names, do: Enum.map(@templates, & &1.name)
end
