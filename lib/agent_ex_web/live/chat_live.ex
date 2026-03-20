defmodule AgentExWeb.ChatLive do
  use AgentExWeb, :live_view

  alias AgentEx.EventLoop
  alias AgentEx.EventLoop.Event

  import AgentExWeb.ChatComponents

  @providers %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "moonshot" => :moonshot
  }

  @impl true
  def mount(_params, _session, socket) do
    default_provider = Application.get_env(:agent_ex, :chat_provider, "openai")

    default_model =
      Application.get_env(:agent_ex, :chat_model, default_model_for(default_provider))

    {:ok,
     assign(socket,
       messages: [],
       events: [],
       stages: [],
       thinking: false,
       run_id: nil,
       input: "",
       provider: default_provider,
       model: default_model
     )}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) when message != "" do
    # Add user message to display
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # Generate a run ID
    run_id = "run-#{System.unique_integer([:positive])}"

    # Subscribe to events
    EventLoop.subscribe(run_id)

    # Start the agent run
    {:ok, tool_agent} = AgentEx.ToolAgent.start_link(tools: [])
    client = build_model_client(socket.assigns.provider, socket.assigns.model)

    input_messages = [
      AgentEx.Message.system("You are a helpful AI assistant."),
      AgentEx.Message.user(message)
    ]

    EventLoop.run(run_id, tool_agent, client, input_messages, [])

    {:noreply,
     assign(socket,
       messages: messages,
       events: [],
       stages: [],
       thinking: true,
       run_id: run_id,
       input: ""
     )}
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("select_provider", %{"provider" => provider}, socket) do
    model = default_model_for(provider)
    {:noreply, assign(socket, provider: provider, model: model)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, model: model)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, messages: [], events: [], stages: [])}
  end

  @impl true
  def handle_info(%Event{type: :think_start} = _event, socket) do
    {:noreply, assign(socket, thinking: true)}
  end

  def handle_info(%Event{type: :think_complete} = event, socket) do
    events = socket.assigns.events ++ [event]
    {:noreply, assign(socket, thinking: false, events: events)}
  end

  def handle_info(%Event{type: :tool_call} = event, socket) do
    events = socket.assigns.events ++ [event]

    stages =
      socket.assigns.stages ++
        [%{name: event.data.tool_name, status: :running}]

    {:noreply, assign(socket, events: events, stages: stages)}
  end

  def handle_info(%Event{type: :tool_result} = event, socket) do
    events = socket.assigns.events ++ [event]

    stages =
      Enum.map(socket.assigns.stages, fn stage ->
        if stage.status == :running, do: %{stage | status: :complete}, else: stage
      end)

    {:noreply, assign(socket, events: events, stages: stages)}
  end

  def handle_info(%Event{type: :pipeline_complete} = event, socket) do
    content = event.data[:final_content] || "No response."
    messages = socket.assigns.messages ++ [%{role: :assistant, content: content}]

    {:noreply,
     assign(socket,
       messages: messages,
       thinking: false,
       stages: [],
       run_id: nil
     )}
  end

  def handle_info(%Event{type: :pipeline_error} = event, socket) do
    reason = event.data[:reason] || "Unknown error"
    messages = socket.assigns.messages ++ [%{role: :assistant, content: "Error: #{reason}"}]

    {:noreply,
     assign(socket,
       messages: messages,
       thinking: false,
       stages: [],
       run_id: nil
     )}
  end

  def handle_info(%Event{} = event, socket) do
    events = socket.assigns.events ++ [event]
    {:noreply, assign(socket, events: events)}
  end

  # Handle Task completion
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  # -- Helpers --

  @models_by_provider %{
    "openai" => ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "o3-mini"],
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
end
