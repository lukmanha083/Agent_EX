defmodule AgentExWeb.ChatLive do
  use AgentExWeb, :live_view

  alias AgentEx.{EventLoop, Memory}
  alias AgentEx.EventLoop.Event

  import AgentExWeb.ChatComponents

  require Logger

  @agent_id "chat"

  @providers %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "moonshot" => :moonshot
  }

  @impl true
  def mount(_params, session, socket) do
    default_provider = Application.get_env(:agent_ex, :chat_provider, "openai")

    default_model =
      Application.get_env(:agent_ex, :chat_model, default_model_for(default_provider))

    session_id = session["chat_session_id"]

    # Start or reuse memory session
    {messages, run_id, events} =
      case Memory.start_session(@agent_id, session_id) do
        {:ok, _} ->
          # New session
          {[], nil, []}

        {:error, {:already_started, _}} ->
          # Reconnect — restore conversation from working memory
          restored = restore_messages(session_id)
          {restored, nil, []}

        {:error, reason} ->
          Logger.warning("Failed to start memory session: #{inspect(reason)}")
          {[], nil, []}
      end

    {:ok,
     assign(socket,
       messages: messages,
       events: events,
       stages: [],
       thinking: false,
       run_id: run_id,
       input: "",
       provider: default_provider,
       model: default_model,
       tools: load_chat_tools(),
       session_id: session_id
     )}
  end

  @impl true
  def terminate(_reason, _socket) do
    # Don't stop the memory session here — it's tied to the HTTP cookie
    # and must survive LiveView reconnects (longpoll → websocket transition).
    # Sessions are reset explicitly via "clear" or lost on server restart.
    :ok
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) when message != "" do
    # Add user message to display
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # Cancel and unsubscribe from previous run if any
    if socket.assigns.run_id do
      EventLoop.cancel(socket.assigns.run_id)
      Phoenix.PubSub.unsubscribe(AgentEx.PubSub, "run:#{socket.assigns.run_id}")
    end

    # Generate a run ID
    run_id = "run-#{System.unique_integer([:positive])}"

    # Subscribe to events
    EventLoop.subscribe(run_id)

    tools = socket.assigns.tools

    # Start the agent run
    case AgentEx.ToolAgent.start_link(tools: tools) do
      {:ok, tool_agent} ->
        client = build_model_client(socket.assigns.provider, socket.assigns.model)

        # Only pass system prompt + latest user message;
        # the memory system injects conversation history from Tier 1
        # and context from Tier 2/3/KG
        input_messages = [
          AgentEx.Message.system("You are a helpful AI assistant."),
          AgentEx.Message.user(message)
        ]

        memory_opts = %{agent_id: @agent_id, session_id: socket.assigns.session_id}
        EventLoop.run(run_id, tool_agent, client, input_messages, tools, memory: memory_opts)

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

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("select_provider", %{"provider" => provider}, socket) do
    model = default_model_for(provider)
    {:noreply, reset_conversation(socket) |> assign(provider: provider, model: model)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, reset_conversation(socket) |> assign(model: model)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, reset_conversation(socket)}
  end

  @impl true
  def handle_info(%Event{} = event, socket) do
    if event.run_id == socket.assigns.run_id do
      handle_run_event(event, socket)
    else
      # Ignore stale events from previous runs
      {:noreply, socket}
    end
  end

  # Handle Task completion
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

    {:noreply,
     assign(socket,
       messages: messages,
       events: [],
       thinking: false,
       stages: [],
       run_id: nil
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

  @models_by_provider %{
    "openai" => [
      "gpt-4o",
      "gpt-4o-mini",
      "gpt-5.4",
      "gpt-5.4-mini",
      "gpt-5.4-nano",
      "gpt-5.4-pro",
      "o3-mini"
    ],
    "anthropic" => [
      "claude-sonnet-4-5-20250514",
      "claude-haiku-4-5-20251001",
      "claude-opus-4-20250514"
    ],
    "moonshot" => ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"]
  }

  def models_for_provider(provider), do: Map.get(@models_by_provider, provider, [])

  def provider_options,
    do: [{"OpenAI", "openai"}, {"Anthropic", "anthropic"}, {"Moonshot", "moonshot"}]

  defp reset_conversation(socket) do
    if socket.assigns.run_id do
      EventLoop.cancel(socket.assigns.run_id)
      Phoenix.PubSub.unsubscribe(AgentEx.PubSub, "run:#{socket.assigns.run_id}")
    end

    Memory.stop_session(@agent_id, socket.assigns.session_id)
    Memory.start_session(@agent_id, socket.assigns.session_id)

    assign(socket, messages: [], events: [], stages: [], thinking: false, run_id: nil)
  end

  defp default_model_for("openai"), do: "gpt-4o-mini"
  defp default_model_for("anthropic"), do: "claude-haiku-4-5-20251001"
  defp default_model_for("moonshot"), do: "moonshot-v1-8k"
  defp default_model_for(_), do: "gpt-4o-mini"

  defp build_model_client(provider, model) do
    provider_atom = Map.get(@providers, provider, :openai)

    AgentEx.ModelClient.new(
      model: model,
      provider: provider_atom
    )
  end

  def tool_status(call_id, events) do
    has_result =
      Enum.any?(events, fn e ->
        e.type == :tool_result and e.data[:call_id] == call_id
      end)

    if has_result, do: :complete, else: :running
  end

  def tool_result_content(call_id, events) do
    Enum.find_value(events, fn e ->
      if e.type == :tool_result and e.data[:call_id] == call_id,
        do: e.data[:content]
    end)
  end

  defp restore_messages(session_id) do
    Memory.get_messages(@agent_id, session_id)
    |> Enum.map(fn msg ->
      role =
        case msg.role do
          r when is_atom(r) -> r
          "user" -> :user
          "assistant" -> :assistant
          "system" -> :system
          other -> String.to_existing_atom(other)
        end

      %{role: role, content: msg.content}
    end)
  rescue
    _ -> []
  end

  # Phase 5 cleanup: replace with agent-configured tools
  defp load_chat_tools do
    case Application.get_env(:agent_ex, :chat_tools, []) do
      :demo -> demo_tools()
      tools when is_list(tools) -> tools
    end
  end

  defp demo_tools do
    [
      AgentEx.Tool.new(
        name: "get_system_info",
        description: "Get OS name, kernel version, and architecture",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        kind: :read,
        function: fn _args ->
          {os_output, 0} = System.cmd("uname", ["-srm"])
          {:ok, String.trim(os_output)}
        end
      ),
      AgentEx.Tool.new(
        name: "get_disk_usage",
        description: "Get disk space usage for all mounted filesystems",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        kind: :read,
        function: fn _args ->
          {df_output, 0} = System.cmd("df", ["-h"])
          {:ok, df_output}
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
