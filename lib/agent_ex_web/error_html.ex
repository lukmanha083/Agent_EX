defmodule AgentExWeb.ErrorHTML do
  @moduledoc """
  Error page renderer for HTML requests.
  """

  use AgentExWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
