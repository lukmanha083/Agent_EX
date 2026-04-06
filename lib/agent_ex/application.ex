defmodule AgentEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TwMerge.Cache,
      # Database
      AgentEx.Repo,

      # PubSub for event broadcasting (EventLoop → LiveView)
      {Phoenix.PubSub, name: AgentEx.PubSub},

      # Task supervisor for async EventLoop runs
      {Task.Supervisor, name: AgentEx.TaskSupervisor},

      # Agent framework: Registry for named tool agents
      {Registry, keys: :unique, name: AgentEx.Registry},

      # Plugin system: DynamicSupervisor for stateful plugins
      {DynamicSupervisor, name: AgentEx.PluginSupervisor, strategy: :one_for_one},

      # Per-project DETS lifecycle manager (must start before stores)
      AgentEx.DetsManager,

      # Agent config store (ETS + lazy per-project DETS)
      AgentEx.AgentStore,

      # HTTP tool config store (ETS + lazy per-project DETS)
      AgentEx.HttpToolStore,

      # EventLoop: ETS-based run tracking
      AgentEx.EventLoop.RunRegistry,

      # Orchestrator task list (ETS-backed)
      AgentEx.TaskList,

      # Memory system: Registry for per-session working memory
      {Registry, keys: :unique, name: AgentEx.Memory.SessionRegistry},
      AgentEx.Memory.WorkingMemory.Supervisor,
      AgentEx.Memory.PersistentMemory.Store,
      AgentEx.Memory.ProceduralMemory.Store,
      AgentEx.Memory.SemanticMemory.Store,
      AgentEx.Memory.KnowledgeGraph.Store,

      # Phoenix web endpoint (must be last)
      AgentExWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: AgentEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
