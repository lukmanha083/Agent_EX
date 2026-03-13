defmodule AgentEx.Intervention.LogHandler do
  @moduledoc """
  Logs every tool call without blocking. Always approves.

  Useful for audit trails — see what tools the LLM is calling and with
  what arguments, without affecting execution.

  ## Usage

      AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
        intervention: [AgentEx.Intervention.LogHandler]
      )
  """

  @behaviour AgentEx.Intervention

  alias AgentEx.Message.FunctionCall

  require Logger

  @impl true
  def on_call(%FunctionCall{id: id, name: name, arguments: args}, tool, %{iteration: iter}) do
    kind = if tool, do: tool.kind, else: :unknown

    Logger.info(
      "Intervention [LOG] iteration=#{iter} tool=#{name} kind=#{kind} call_id=#{id} args=#{args}"
    )

    :approve
  end
end
