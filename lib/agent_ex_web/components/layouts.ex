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

  @doc "Generate initials from a username or email string."
  def initials(name) when is_binary(name) do
    name
    |> String.split(~r/[_@.\s]/)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  def initials(_), do: "?"
end
