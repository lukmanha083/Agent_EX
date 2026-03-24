defmodule AgentExWeb.Layouts do
  @moduledoc """
  Layout components for the AgentEx web interface.
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents

  embed_templates("layouts/*")

  @doc "Check if a nav link is active based on the current LiveView module."
  def nav_active?(socket, module) do
    socket.view == module
  end
end
