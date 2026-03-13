defmodule AgentEx do
  @moduledoc """
  AgentEx - AutoGen core patterns reimplemented in Elixir/OTP.

  Maps AutoGen's agent framework concepts to native BEAM primitives:

  - AutoGen Agent       → GenServer process
  - AgentRuntime        → Supervisor tree + Registry
  - send_message()      → GenServer.call/cast + message passing
  - asyncio.gather      → Task.async_stream (true parallelism)
  - CancellationToken   → Process monitors + Task.shutdown
  - InterventionHandler → Middleware pipeline
  - ToolAgent           → AgentEx.ToolAgent GenServer
  """
end
