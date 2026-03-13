defmodule AgentEx.Intervention.WriteGateHandler do
  @moduledoc """
  Gate `:write` tools with an allowlist. Reads are always approved.

  Like `chmod` on specific files — you grant write permission per tool.

  Returns a **function handler** (closure) that captures the allowlist,
  so no process dictionary or global state needed.

  ## Usage

      # Only "send_email" is allowed to write
      handler = AgentEx.Intervention.WriteGateHandler.new(
        allowed_writes: ["send_email"]
      )

      AgentEx.ToolCallerLoop.run(tool_agent, client, messages, tools,
        intervention: [handler]
      )

  ## Permission model

      Tool kind    │ In allowlist? │ Decision
      ─────────────┼───────────────┼──────────
      :read        │ n/a           │ :approve
      :write       │ yes           │ :approve
      :write       │ no            │ :reject
      unknown/nil  │ n/a           │ :approve
  """

  alias AgentEx.Message.FunctionCall
  alias AgentEx.Tool

  require Logger

  @doc """
  Create a function handler with the given allowlist.

  Returns a function compatible with the intervention pipeline.
  """
  @spec new(keyword()) :: AgentEx.Intervention.handler()
  def new(opts \\ []) do
    allowed =
      opts
      |> Keyword.get(:allowed_writes, [])
      |> MapSet.new()

    fn %FunctionCall{name: name}, tool, _context ->
      cond do
        # Unknown tool — let ToolAgent handle the error
        is_nil(tool) ->
          :approve

        # Read tool — always allowed
        Tool.read?(tool) ->
          :approve

        # Write tool in allowlist — permitted
        Tool.write?(tool) and MapSet.member?(allowed, name) ->
          Logger.debug("Intervention: approved write tool '#{name}' (in allowlist)")
          :approve

        # Write tool NOT in allowlist — denied
        Tool.write?(tool) ->
          Logger.info("Intervention: REJECTED write tool '#{name}' — not in allowlist")
          :reject

        # Fallback
        true ->
          :approve
      end
    end
  end
end
