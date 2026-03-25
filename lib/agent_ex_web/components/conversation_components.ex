defmodule AgentExWeb.ConversationComponents do
  @moduledoc false
  use AgentExWeb, :html

  import AgentExWeb.CoreComponents, except: [button: 1]
  import SaladUI.Button

  alias Phoenix.LiveView.JS

  attr(:conversations, :list, required: true)
  attr(:current_id, :any, default: nil)

  def conversation_sidebar(assigns) do
    grouped = group_by_date(assigns.conversations)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div class="flex flex-col h-full bg-gray-900/50 border-r border-gray-800">
      <div class="p-3 border-b border-gray-800">
        <.button variant="outline" class="w-full justify-start gap-2 text-sm" phx-click="new_chat">
          <.icon name="hero-plus" class="w-4 h-4" />
          New Chat
        </.button>
      </div>

      <div class="flex-1 overflow-y-auto p-2 space-y-3">
        <div :for={{label, convos} <- @grouped} :if={convos != []}>
          <p class="px-2 py-1 text-[11px] font-medium text-gray-500 uppercase tracking-wider">
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

        <p :if={@conversations == []} class="px-2 py-4 text-xs text-gray-600 text-center">
          No conversations yet
        </p>
      </div>
    </div>
    """
  end

  attr(:conversation, :map, required: true)
  attr(:active, :boolean, default: false)

  def conversation_item(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-2 px-2 py-2 rounded-md text-sm transition-colors group",
      @active && "bg-gray-800 text-white" || "text-gray-400 hover:bg-gray-800/50 hover:text-gray-200"
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
        <.icon name="hero-trash" class="w-3.5 h-3.5" />
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
