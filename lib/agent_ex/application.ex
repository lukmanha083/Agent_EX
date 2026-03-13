defmodule AgentEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Agent framework: Registry for named tool agents
      {Registry, keys: :unique, name: AgentEx.Registry},

      # Memory system: Registry for per-session working memory
      {Registry, keys: :unique, name: AgentEx.Memory.SessionRegistry},
      AgentEx.Memory.WorkingMemory.Supervisor,
      AgentEx.Memory.PersistentMemory.Store,
      AgentEx.Memory.SemanticMemory.Store,
      AgentEx.Memory.KnowledgeGraph.Store
    ]

    opts = [strategy: :one_for_one, name: AgentEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
