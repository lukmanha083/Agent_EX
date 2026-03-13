defmodule AgentEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for named tool agents — maps to AutoGen's AgentId routing
      {Registry, keys: :unique, name: AgentEx.Registry}
    ]

    opts = [strategy: :one_for_one, name: AgentEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
