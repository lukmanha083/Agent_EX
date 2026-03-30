defmodule AgentExWeb.ChatLive do
  use AgentExWeb, :live_view

  alias AgentEx.{AgentConfig, AgentStore, Chat, EventLoop, Memory}
  alias AgentEx.EventLoop.Event

  import AgentExWeb.ChatComponents
  import AgentExWeb.ConversationComponents
  import AgentExWeb.CoreComponents, except: [button: 1]
  import AgentExWeb.ProviderHelpers, only: [default_model_for: 1, provider_to_atom: 1]
  import SaladUI.Button

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns[:current_project]

    if is_nil(project) do
      {:ok,
       socket
       |> put_flash(:error, "No project available. Please create one first.")
       |> redirect(to: ~p"/projects")}
    else
      agents = AgentStore.list(user.id, project.id)
      active_agent = List.first(agents)

      {provider, model, tools, system_prompt} = load_from_agent(active_agent, user)
      conversations = Chat.list_conversations(user.id, project.id)

      {:ok,
       assign(socket,
         messages: [],
         events: [],
         stages: [],
         thinking: false,
         run_id: nil,
         input: "",
         provider: provider,
         model: model,
         tools: tools,
         system_prompt: system_prompt,
         active_agent: active_agent,
         agents: agents,
         agent_id: project_agent_id(user, project),
         project: project,
         user_initials: AgentExWeb.Layouts.initials(user.username || user.email),
         timezone: user.timezone || "Etc/UTC",
         conversation: nil,
         conversations: conversations
       )}
    end
  end

  @impl true
  def handle_params(%{"conversation_id" => id}, _uri, socket) do
    # Skip reload if this conversation is already loaded (e.g. from ensure_conversation)
    if socket.assigns.conversation && to_string(socket.assigns.conversation.id) == to_string(id) do
      {:noreply, socket}
    else
      user = socket.assigns.current_scope.user
      project = socket.assigns.project

      case Chat.get_user_conversation(user.id, project.id, id) do
        nil ->
          {:noreply,
           socket
           |> put_flash(:error, "Conversation not found")
           |> push_navigate(to: ~p"/chat")}

        conversation ->
          {:noreply, load_conversation(socket, conversation)}
      end
    end
  end

  def handle_params(_params, _uri, socket) do
    # /chat with no conversation_id — show empty state
    {:noreply,
     assign(socket,
       conversation: nil,
       messages: [],
       events: [],
       stages: [],
       thinking: false,
       run_id: nil
     )}
  end

  @impl true
  def terminate(_reason, _socket), do: :ok

  @impl true
  def handle_event("new_chat", _params, socket) do
    socket = cancel_active_run(socket)
    {:noreply, push_patch(socket, to: ~p"/chat")}
  end

  def handle_event("send", %{"message" => raw_message}, socket) do
    message = String.trim(raw_message)

    if message == "" do
      {:noreply, socket}
    else
      socket = ensure_conversation(socket, message)

      case socket.assigns.conversation do
        nil ->
          {:noreply, socket}

        conversation ->
          send_message(socket, conversation, message)
      end
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    if socket.assigns.run_id do
      EventLoop.cancel(socket.assigns.run_id)
      Phoenix.PubSub.unsubscribe(AgentEx.PubSub, "run:#{socket.assigns.run_id}")
    end

    messages =
      socket.assigns.messages ++ [%{role: :assistant, content: "Cancelled by user."}]

    {:noreply,
     assign(socket, messages: messages, events: [], stages: [], thinking: false, run_id: nil)}
  end

  def handle_event("clear", _params, socket) do
    socket = cancel_active_run(socket)
    {:noreply, push_patch(socket, to: ~p"/chat")}
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    project = socket.assigns.project

    with conversation when not is_nil(conversation) <-
           Chat.get_user_conversation(user.id, project.id, id),
         {:ok, _} <- Chat.delete_conversation(conversation) do
      conversations = Chat.list_conversations(user.id, project.id)
      socket = assign(socket, conversations: conversations)

      viewing_deleted? =
        socket.assigns.conversation && socket.assigns.conversation.id == conversation.id

      if viewing_deleted?,
        do: {:noreply, push_patch(socket, to: ~p"/chat")},
        else: {:noreply, socket}
    else
      nil -> {:noreply, socket}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to delete conversation")}
    end
  end

  @impl true
  def handle_info(%Event{} = event, socket) do
    if event.run_id == socket.assigns.run_id do
      handle_run_event(event, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info({:title_updated, conversation_id, title}, socket) do
    conversations =
      Chat.list_conversations(socket.assigns.current_scope.user.id, socket.assigns.project.id)

    conversation =
      if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
        %{socket.assigns.conversation | title: title}
      else
        socket.assigns.conversation
      end

    {:noreply, assign(socket, conversations: conversations, conversation: conversation)}
  end

  def handle_info({ref, _result}, socket) when is_reference(ref) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, socket) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    if socket.assigns.thinking and socket.assigns.run_id do
      EventLoop.RunRegistry.error_run(socket.assigns.run_id)
      error_text = "Agent crashed: #{inspect(reason)}"
      messages = socket.assigns.messages ++ [%{role: :assistant, content: error_text}]
      {:noreply, assign(socket, messages: messages, thinking: false, stages: [], run_id: nil)}
    else
      {:noreply, socket}
    end
  end

  # -- Run event dispatch --

  defp handle_run_event(%Event{type: :think_start}, socket) do
    {:noreply, assign(socket, thinking: true)}
  end

  defp handle_run_event(%Event{type: :think_complete} = event, socket) do
    events = socket.assigns.events ++ [event]
    {:noreply, assign(socket, thinking: false, events: events)}
  end

  defp handle_run_event(%Event{type: :tool_call} = event, socket) do
    events = socket.assigns.events ++ [event]

    stages =
      socket.assigns.stages ++
        [%{name: event.data.tool_name, call_id: event.data.call_id, status: :running}]

    {:noreply, assign(socket, events: events, stages: stages)}
  end

  defp handle_run_event(%Event{type: :tool_result} = event, socket) do
    events = socket.assigns.events ++ [event]
    result_call_id = event.data[:call_id]

    stages =
      Enum.map(socket.assigns.stages, fn stage ->
        if stage.status == :running and stage.call_id == result_call_id,
          do: %{stage | status: :complete},
          else: stage
      end)

    {:noreply, assign(socket, events: events, stages: stages)}
  end

  defp handle_run_event(%Event{type: :pipeline_complete} = event, socket) do
    content = event.data[:final_content] || "No response."
    messages = socket.assigns.messages ++ [%{role: :assistant, content: content}]

    # Save assistant message to DB
    if socket.assigns.conversation do
      case Chat.create_message(%{
             conversation_id: socket.assigns.conversation.id,
             role: "assistant",
             content: content
           }) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to persist assistant message: #{inspect(reason)}")
      end

      Chat.touch_conversation(socket.assigns.conversation)
      maybe_generate_title(socket.assigns.conversation, messages, content)
    end

    {:noreply,
     assign(socket,
       messages: messages,
       events: [],
       thinking: false,
       stages: [],
       run_id: nil,
       conversations:
         Chat.list_conversations(socket.assigns.current_scope.user.id, socket.assigns.project.id)
     )}
  end

  defp handle_run_event(%Event{type: :pipeline_error} = event, socket) do
    reason = event.data[:reason] || "Unknown error"
    messages = socket.assigns.messages ++ [%{role: :assistant, content: "Error: #{reason}"}]

    {:noreply,
     assign(socket,
       messages: messages,
       events: [],
       thinking: false,
       stages: [],
       run_id: nil
     )}
  end

  defp handle_run_event(%Event{} = event, socket) do
    events = socket.assigns.events ++ [event]
    {:noreply, assign(socket, events: events)}
  end

  # -- Helpers --

  defp send_message(socket, conversation, message) do
    # Save user message to DB
    case Chat.create_message(%{
           conversation_id: conversation.id,
           role: "user",
           content: message
         }) do
      {:ok, _msg} -> :ok
      {:error, reason} -> Logger.warning("Failed to persist user message: #{inspect(reason)}")
    end

    # Add user message to display
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # Cancel previous run if any
    if socket.assigns.run_id do
      EventLoop.cancel(socket.assigns.run_id)
      Phoenix.PubSub.unsubscribe(AgentEx.PubSub, "run:#{socket.assigns.run_id}")
    end

    run_id = "run-#{System.unique_integer([:positive])}"
    EventLoop.subscribe(run_id)

    tools = socket.assigns.tools
    session_id = "conversation-#{conversation.id}"

    case AgentEx.ToolAgent.start_link(tools: tools) do
      {:ok, tool_agent} ->
        client = build_model_client(socket.assigns.provider, socket.assigns.model)

        input_messages = [
          AgentEx.Message.system(socket.assigns.system_prompt),
          AgentEx.Message.user(message)
        ]

        memory_opts = %{
          user_id: socket.assigns.current_scope.user.id,
          project_id: socket.assigns.project.id,
          agent_id: socket.assigns.agent_id,
          session_id: session_id
        }

        EventLoop.run(run_id, tool_agent, client, input_messages, tools,
          memory: memory_opts,
          metadata: %{user_id: socket.assigns.current_scope.user.id}
        )

        {:noreply,
         assign(socket,
           messages: messages,
           events: [],
           stages: [],
           thinking: true,
           run_id: run_id,
           input: ""
         )}

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(AgentEx.PubSub, "run:#{run_id}")
        error_msg = %{role: :assistant, content: "Failed to start agent: #{inspect(reason)}"}
        {:noreply, assign(socket, messages: messages ++ [error_msg], input: "")}
    end
  end

  defp ensure_conversation(socket, first_message) do
    case socket.assigns.conversation do
      nil ->
        user = socket.assigns.current_scope.user
        project = socket.assigns.project
        title = Chat.auto_title(first_message)

        case Chat.create_conversation(%{
               user_id: user.id,
               project_id: project.id,
               title: title,
               model: socket.assigns.model,
               provider: socket.assigns.provider
             }) do
          {:ok, conversation} ->
            session_id = "conversation-#{conversation.id}"
            Memory.start_session(user.id, project.id, socket.assigns.agent_id, session_id)

            conversations = Chat.list_conversations(user.id, project.id)

            socket
            |> assign(conversation: conversation, conversations: conversations)
            |> push_patch(to: ~p"/chat/#{conversation.id}", replace: true)

          {:error, reason} ->
            Logger.warning("Failed to create conversation: #{inspect(reason)}")
            put_flash(socket, :error, "Failed to create conversation")
        end

      _existing ->
        socket
    end
  end

  defp load_conversation(socket, conversation) do
    socket = cancel_active_run(socket)

    # Load messages from Postgres
    db_messages =
      Chat.list_messages(conversation.id)
      |> Enum.map(fn msg ->
        %{role: role_atom(msg.role), content: msg.content}
      end)

    # Hydrate Tier 1 working memory
    session_id = "conversation-#{conversation.id}"
    user = socket.assigns.current_scope.user
    project = socket.assigns.project
    agent_id = socket.assigns.agent_id

    case Memory.start_session(user.id, project.id, agent_id, session_id) do
      {:ok, _} ->
        hydrate_working_memory(user.id, project.id, agent_id, session_id, db_messages)

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to start memory session: #{inspect(reason)}")
    end

    assign(socket,
      conversation: conversation,
      messages: db_messages,
      events: [],
      stages: [],
      thinking: false,
      run_id: nil
    )
  end

  defp cancel_active_run(socket) do
    if socket.assigns.run_id do
      EventLoop.cancel(socket.assigns.run_id)
      Phoenix.PubSub.unsubscribe(AgentEx.PubSub, "run:#{socket.assigns.run_id}")
      assign(socket, run_id: nil, thinking: false)
    else
      socket
    end
  end

  defp hydrate_working_memory(user_id, project_id, agent_id, session_id, messages) do
    Enum.each(messages, fn msg ->
      Memory.add_message(
        user_id,
        project_id,
        agent_id,
        session_id,
        to_string(msg.role),
        msg.content
      )
    end)
  rescue
    e ->
      Logger.warning("Failed to hydrate working memory: #{inspect(e)}")
  end

  defp build_model_client(provider, model) do
    AgentEx.ModelClient.new(
      model: model,
      provider: provider_to_atom(provider)
    )
  end

  def tool_status(call_id, events) do
    has_result =
      Enum.any?(events, fn e ->
        e.type == :tool_result and e.data[:call_id] == call_id
      end)

    if has_result, do: :complete, else: :running
  end

  defp maybe_generate_title(conversation, messages, assistant_content) do
    if length(messages) == 2 do
      user_msg = Enum.find(messages, &(&1.role == :user))

      if user_msg do
        Chat.generate_title_async(conversation, user_msg.content, assistant_content,
          notify_pid: self()
        )
      end
    end
  end

  defp role_atom("user"), do: :user
  defp role_atom("assistant"), do: :assistant
  defp role_atom("system"), do: :system
  defp role_atom(_other), do: :user

  defp project_agent_id(user, project), do: "u#{user.id}_p#{project.id}_chat"

  defp load_from_agent(nil, user) do
    provider = user.provider || "openai"
    model = user.model || default_model_for(provider)
    {provider, model, default_tools(), "You are a helpful AI assistant."}
  end

  defp load_from_agent(agent, _user) do
    system_prompt = AgentConfig.build_system_messages(agent)

    prompt =
      if system_prompt in [nil, ""], do: "You are a helpful AI assistant.", else: system_prompt

    {agent.provider, agent.model, default_tools(), prompt}
  end

  defp default_tools do
    [
      AgentEx.Tool.new(
        name: "get_system_info",
        description: "Get OS name, kernel version, and architecture",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        kind: :read,
        function: fn _args ->
          case System.cmd("uname", ["-srm"], stderr_to_stdout: true) do
            {output, 0} -> {:ok, String.trim(output)}
            {output, code} -> {:error, "uname failed (exit #{code}): #{String.trim(output)}"}
          end
        end
      ),
      AgentEx.Tool.new(
        name: "get_disk_usage",
        description: "Get disk space usage for all mounted filesystems",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        kind: :read,
        function: fn _args ->
          case System.cmd("df", ["-h"], stderr_to_stdout: true) do
            {output, 0} -> {:ok, output}
            {output, code} -> {:error, "df failed (exit #{code}): #{String.trim(output)}"}
          end
        end
      ),
      AgentEx.Tool.new(
        name: "get_current_time",
        description: "Get the current date and time with timezone",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        kind: :read,
        function: fn _args ->
          {:ok, DateTime.utc_now() |> DateTime.to_string()}
        end
      )
    ]
  end
end
