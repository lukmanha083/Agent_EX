defmodule AgentExWeb.ConversationComponents do
  @moduledoc false
  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]

  attr(:conversations, :list, required: true)
  attr(:current_id, :any, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  def conversation_sidebar(assigns) do
    grouped = group_by_date(assigns.conversations, assigns.timezone)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div class="flex flex-col h-full w-full bg-gray-900 border-r border-gray-800" data-testid="conversation-sidebar">
      <!-- Header -->
      <div class="flex items-center justify-between h-14 px-3 border-b border-gray-800">
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
    <div
      data-testid={"conversation-item-#{@conversation.id}"}
      class={[
        "flex items-center gap-2 px-2 py-1.5 rounded-md text-sm transition-colors group",
        @active && "bg-gray-800 text-white font-medium" || "text-gray-400 hover:bg-gray-800/50 hover:text-gray-200"
      ]}
    >
      <.link
        patch={~p"/chat/#{@conversation.id}"}
        class="flex items-center gap-2 flex-1 min-w-0"
      >
        <.icon name="hero-chat-bubble-left" class="w-4 h-4 shrink-0" />
        <span class="truncate">{@conversation.title || "New conversation"}</span>
      </.link>
      <button
        type="button"
        phx-click="delete_conversation"
        phx-value-id={@conversation.id}
        data-confirm="Delete this conversation?"
        class="p-1 rounded text-gray-600 hover:text-red-400 transition-colors shrink-0"
        aria-label="Delete conversation"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3">
          <path fill-rule="evenodd" d="M8.75 1A2.75 2.75 0 0 0 6 3.75v.443c-.795.077-1.584.176-2.365.298a.75.75 0 1 0 .23 1.482l.149-.022.841 10.518A2.75 2.75 0 0 0 7.596 19h4.807a2.75 2.75 0 0 0 2.742-2.53l.841-10.519.149.023a.75.75 0 0 0 .23-1.482A41.03 41.03 0 0 0 14 4.193V3.75A2.75 2.75 0 0 0 11.25 1h-2.5ZM10 4c.84 0 1.673.025 2.5.075V3.75c0-.69-.56-1.25-1.25-1.25h-2.5c-.69 0-1.25.56-1.25 1.25v.325C8.327 4.025 9.16 4 10 4ZM8.58 7.72a.75.75 0 0 0-1.5.06l.3 7.5a.75.75 0 1 0 1.5-.06l-.3-7.5Zm4.34.06a.75.75 0 1 0-1.5-.06l-.3 7.5a.75.75 0 1 0 1.5.06l.3-7.5Z" clip-rule="evenodd" />
        </svg>
      </button>
    </div>
    """
  end

  defp group_by_date(conversations, timezone) do
    today = local_today(timezone)
    yesterday = Date.add(today, -1)

    {today_list, yesterday_list, older_list} =
      Enum.reduce(conversations, {[], [], []}, fn convo, {t, y, o} ->
        date = conversation_date(convo.updated_at, timezone)

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

  defp local_today(timezone) do
    case DateTime.now(timezone) do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

  defp conversation_date(%DateTime{} = dt, timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      _ -> DateTime.to_date(dt)
    end
  end

  defp conversation_date(_, _), do: nil
end
