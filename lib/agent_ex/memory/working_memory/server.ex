defmodule AgentEx.Memory.WorkingMemory.Server do
  @moduledoc """
  Per-user, per-project, per-agent, per-session GenServer holding conversation messages (Tier 1).
  Registered via Registry keyed on `{user_id, project_id, agent_id, session_id}`.
  """

  use GenServer

  @behaviour AgentEx.Memory.Tier

  alias AgentEx.Memory.Message

  defstruct [:user_id, :project_id, :agent_id, :session_id, :max_messages, messages: []]

  # --- Client API ---

  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    project_id = Keyword.fetch!(opts, :project_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    session_id = Keyword.fetch!(opts, :session_id)
    max = Keyword.get(opts, :max_messages, default_max_messages())

    GenServer.start_link(
      __MODULE__,
      {user_id, project_id, agent_id, session_id, max},
      name: via(user_id, project_id, agent_id, session_id)
    )
  end

  def add_message(user_id, project_id, agent_id, session_id, role, content) do
    GenServer.call(via(user_id, project_id, agent_id, session_id), {:add_message, role, content})
  end

  def get_messages(user_id, project_id, agent_id, session_id) do
    GenServer.call(via(user_id, project_id, agent_id, session_id), :get_messages)
  end

  def get_recent(user_id, project_id, agent_id, session_id, n) do
    GenServer.call(via(user_id, project_id, agent_id, session_id), {:get_recent, n})
  end

  def clear(user_id, project_id, agent_id, session_id) do
    GenServer.call(via(user_id, project_id, agent_id, session_id), :clear)
  end

  def whereis(user_id, project_id, agent_id, session_id) do
    case Registry.lookup(AgentEx.Memory.SessionRegistry, {user_id, project_id, agent_id, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # --- Tier callbacks ---

  @impl AgentEx.Memory.Tier
  def to_context_messages({user_id, project_id, agent_id}, session_id) do
    messages = get_messages(user_id, project_id, agent_id, session_id)

    Enum.map(messages, fn %Message{role: role, content: content} ->
      %{role: role, content: content}
    end)
  end

  @impl AgentEx.Memory.Tier
  def token_estimate({user_id, project_id, agent_id}, session_id) do
    messages = get_messages(user_id, project_id, agent_id, session_id)
    Enum.reduce(messages, 0, fn msg, acc -> acc + div(String.length(msg.content), 4) end)
  end

  # --- Server callbacks ---

  @impl GenServer
  def init({user_id, project_id, agent_id, session_id, max_messages}) do
    state = %__MODULE__{
      user_id: user_id,
      project_id: project_id,
      agent_id: agent_id,
      session_id: session_id,
      max_messages: max_messages
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:add_message, role, content}, _from, state) do
    message = Message.new(role, content)
    messages = state.messages ++ [message]

    messages =
      if length(messages) > state.max_messages do
        Enum.drop(messages, length(messages) - state.max_messages)
      else
        messages
      end

    {:reply, :ok, %{state | messages: messages}}
  end

  @impl GenServer
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl GenServer
  def handle_call({:get_recent, n}, _from, state) do
    recent = Enum.take(state.messages, -n)
    {:reply, recent, state}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | messages: []}}
  end

  defp via(user_id, project_id, agent_id, session_id) do
    {:via, Registry, {AgentEx.Memory.SessionRegistry, {user_id, project_id, agent_id, session_id}}}
  end

  defp default_max_messages do
    Application.get_env(:agent_ex, :working_memory_max_messages, 50)
  end
end
