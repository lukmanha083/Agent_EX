defmodule AgentExWeb.Layouts do
  @moduledoc """
  Layout components for the AgentEx web interface.
  """

  use AgentExWeb, :html

  import AgentExWeb.CoreComponents

  embed_templates("layouts/*")
end
