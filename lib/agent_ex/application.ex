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

      # Specialist delegation supervisor (Phase 5f)
      {DynamicSupervisor, name: AgentEx.Specialist.DelegationSupervisor, strategy: :one_for_one},

      # EventLoop: ETS-based run tracking
      AgentEx.EventLoop.RunRegistry,

      # Task management (Postgres + ETS cache)
      AgentEx.TaskManager,

      # Memory system: Registry for per-session working memory
      {Registry, keys: :unique, name: AgentEx.Memory.SessionRegistry},
      AgentEx.Memory.WorkingMemory.Supervisor,
      AgentEx.Memory.PersistentMemory.Store,
      AgentEx.Memory.SemanticMemory.Cache,
      AgentEx.Memory.ProceduralMemory.Store,

      # Phoenix web endpoint (must be last)
      AgentExWeb.Endpoint
    ]

    opts = [strategy: :rest_for_one, name: AgentEx.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Register system defaults after Repo is ready (non-blocking).
        # In test, the sandbox may reject the connection — catch and log.
        Task.Supervisor.start_child(AgentEx.TaskSupervisor, fn ->
          try do
            AgentEx.Defaults.register_system_agents()
            AgentEx.Defaults.register_system_mcp_servers()
          rescue
            e ->
              require Logger
              Logger.debug("Defaults: boot registration skipped: #{Exception.message(e)}")
          end
        end)

        {:ok, pid}

      error ->
        error
    end
  end
end
