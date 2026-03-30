defmodule AgentEx.Memory.WorkingMemory.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-user, per-project, per-agent, per-session WorkingMemory.Server processes.
  """

  use DynamicSupervisor

  alias AgentEx.Memory.WorkingMemory.Server

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(user_id, project_id, agent_id, session_id, opts \\ []) do
    spec =
      {AgentEx.Memory.WorkingMemory.Server,
       opts
       |> Keyword.put(:user_id, user_id)
       |> Keyword.put(:project_id, project_id)
       |> Keyword.put(:agent_id, agent_id)
       |> Keyword.put(:session_id, session_id)}

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_session(user_id, project_id, agent_id, session_id) do
    case Server.whereis(user_id, project_id, agent_id, session_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
