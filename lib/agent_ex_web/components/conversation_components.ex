defmodule AgentExWeb.ConversationComponents do
  @moduledoc false
  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]

  alias Phoenix.LiveView.JS

  attr(:conversations, :list, required: true)
  attr(:current_id, :any, default: nil)

  def conversation_sidebar(assigns) do
    grouped = group_by_date(assigns.conversations)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div class="flex flex-col h-full w-full bg-gray-900 border-r border-gray-800">
      <!-- Header -->
      <div class="flex items-center justify-between h-14 pl-3 pr-12 border-b border-gray-800">
        <span class="text-sm font-semibold text-white">History</span>
        <button
          type="button"
          phx-click="new_chat"
          class="flex items-center justify-center w-8 h-8 rounded-md border border-gray-600 hover:bg-gray-800 transition-colors"
          aria-label="New chat"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="white" class="w-4 h-4">
            <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
          </svg>
        </button>
      </div>

      <!-- Conversation list -->
      <nav class="flex-1 overflow-y-auto px-2 py-3 space-y-4">
        <div :for={{label, convos} <- @grouped} :if={convos != []}>
          <p class="px-2 mb-1 text-[11px] font-medium text-gray-500 uppercase tracking-wider">
            {label}
          </p>
          <div class="space-y-0.5">
            <.conversation_item
              :for={convo <- convos}
              conversation={convo}
              active={convo.id == @current_id}
            />
          </div>
        </div>

        <div :if={@conversations == []} class="flex flex-col items-center gap-2 py-8 text-gray-600">
          <.icon name="hero-chat-bubble-left-right" class="w-8 h-8" />
          <p class="text-xs">No conversations yet</p>
        </div>
      </nav>
    </div>
    """
  end

  attr(:conversation, :map, required: true)
  attr(:active, :boolean, default: false)

  def conversation_item(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-2 px-2 py-1.5 rounded-md text-sm transition-colors group",
      @active && "bg-gray-800 text-white font-medium" || "text-gray-400 hover:bg-gray-800/50 hover:text-gray-200"
    ]}>
      <.link
        patch={~p"/chat/#{@conversation.id}"}
        class="flex items-center gap-2 flex-1 min-w-0"
      >
        <.icon name="hero-chat-bubble-left" class="w-4 h-4 shrink-0" />
        <span class="truncate">{@conversation.title || "New conversation"}</span>
      </.link>
      <button
        type="button"
        phx-click={JS.push("delete_conversation", value: %{id: @conversation.id})}
        class="opacity-0 group-hover:opacity-100 p-1 rounded text-gray-500 hover:text-red-400 transition-opacity shrink-0"
        aria-label="Delete conversation"
        data-confirm="Delete this conversation?"
      >
        <.icon name="hero-trash" class="w-3 h-3" />
      </button>
    </div>
    """
  end

  defp group_by_date(conversations) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    {today_list, yesterday_list, older_list} =
      Enum.reduce(conversations, {[], [], []}, fn convo, {t, y, o} ->
        date = conversation_date(convo.updated_at)

        cond do
          date == today -> {[convo | t], y, o}
          date == yesterday -> {t, [convo | y], o}
          true -> {t, y, [convo | o]}
        end
      end)

    [
      {"Today", Enum.reverse(today_list)},
      {"Yesterday", Enum.reverse(yesterday_list)},
      {"Older", Enum.reverse(older_list)}
    ]
  end

  defp conversation_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp conversation_date(_), do: nil
end
