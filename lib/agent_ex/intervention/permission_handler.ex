defmodule AgentEx.Intervention.PermissionHandler do
  @moduledoc """
  Auto-approve `:read` tools, reject `:write` tools.

  Like `chmod 444` — everything is read-only by default.

  ## Usage

      AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
        intervention: [AgentEx.Intervention.PermissionHandler]
      )
  """

  @behaviour AgentEx.Intervention

  alias AgentEx.Message.FunctionCall
  alias AgentEx.Tool

  require Logger

  @impl true
  def on_call(%FunctionCall{name: name}, %Tool{kind: :write}, _context) do
    Logger.info("Intervention: REJECTED write tool '#{name}' — no write permission")
    :reject
  end

  def on_call(_call, _tool, _context), do: :approve
end
