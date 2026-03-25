defmodule AgentExWeb.ChatComponents do
  @moduledoc """
  Components for the chat interface — message bubbles, tool cards,
  thinking indicators, and event timeline.
  """

  use Phoenix.Component

  import SaladUI.Badge
  import SaladUI.Card

  @doc "Renders a chat message bubble."
  attr(:role, :atom, required: true, values: [:user, :assistant, :system, :tool])
  attr(:content, :string, required: true)
  attr(:source, :string, default: nil)

  def message_bubble(assigns) do
    ~H"""
    <div class={[
      "flex gap-3 px-4 py-3",
      @role == :user && "justify-end"
    ]}>
      <div :if={@role != :user} class="flex-shrink-0 w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold bg-indigo-600 text-white">
        {role_icon(@role)}
      </div>

      <div class={[
        "max-w-[75%] rounded-xl px-4 py-2.5 text-sm leading-relaxed",
        message_style(@role)
      ]}>
        <p :if={@source && @role == :assistant} class="text-xs text-gray-500 mb-1">
          {@source}
        </p>
        <div class="whitespace-pre-wrap break-words">{@content}</div>
      </div>

      <div :if={@role == :user} class="flex-shrink-0 w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold bg-gray-600 text-white">
        U
      </div>
    </div>
    """
  end

  @doc "Renders a tool call/result card."
  attr(:name, :string, required: true)
  attr(:status, :atom, default: :pending, values: [:pending, :running, :complete, :error])
  attr(:arguments, :string, default: nil)
  attr(:result, :string, default: nil)

  def tool_card(assigns) do
    ~H"""
    <div class="mx-4 my-2">
      <.card class="bg-gray-900/50 overflow-hidden">
        <.card_header class="flex-row items-center gap-2 px-3 py-2 space-y-0">
          <span class={[
            "w-2 h-2 rounded-full shrink-0",
            status_dot_class(@status)
          ]} />
          <span class="text-xs font-mono text-gray-400">{@name}</span>
          <.badge variant={status_badge_variant(@status)} class="ml-auto text-[10px]">
            {@status}
          </.badge>
        </.card_header>

        <.card_content :if={@arguments} class="px-3 py-2 border-t border-gray-800">
          <p class="text-xs text-gray-600 mb-1">Arguments</p>
          <pre class="text-xs text-gray-400 font-mono overflow-x-auto">{@arguments}</pre>
        </.card_content>

        <.card_content :if={@result} class="px-3 py-2 border-t border-gray-800">
          <p class="text-xs text-gray-600 mb-1">Result</p>
          <pre class={[
            "text-xs font-mono overflow-x-auto",
            @status == :error && "text-red-400" || "text-gray-400"
          ]}>{@result}</pre>
        </.card_content>
      </.card>
    </div>
    """
  end

  @doc "Renders a thinking/loading indicator."
  attr(:active, :boolean, default: false)

  def thinking_indicator(assigns) do
    ~H"""
    <div :if={@active} class="flex items-center gap-2 px-4 py-3">
      <div class="flex-shrink-0 w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold bg-indigo-600 text-white">
        A
      </div>
      <div class="flex gap-1">
        <span class="w-2 h-2 bg-gray-500 rounded-full animate-bounce [animation-delay:0ms]" />
        <span class="w-2 h-2 bg-gray-500 rounded-full animate-bounce [animation-delay:150ms]" />
        <span class="w-2 h-2 bg-gray-500 rounded-full animate-bounce [animation-delay:300ms]" />
      </div>
      <span class="text-xs text-gray-600">Thinking...</span>
    </div>
    """
  end

  @doc "Renders a pipeline stage indicator."
  attr(:stages, :list, default: [])

  def pipeline_stages(assigns) do
    ~H"""
    <div :if={@stages != []} class="flex items-center gap-1.5 px-4 py-2 overflow-x-auto">
      <div :for={{stage, idx} <- Enum.with_index(@stages)} class="flex items-center gap-1.5">
        <span :if={idx > 0} class="w-4 h-px bg-gray-700" />
        <.badge variant={stage_badge_variant(stage.status)} class="font-mono text-[10px]">
          {stage.name}
        </.badge>
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp role_icon(:assistant), do: "A"
  defp role_icon(:system), do: "S"
  defp role_icon(:tool), do: "T"
  defp role_icon(_), do: "?"

  defp message_style(:user), do: "bg-indigo-600 text-white"
  defp message_style(:assistant), do: "bg-gray-800 text-gray-200"
  defp message_style(:system), do: "bg-gray-900 text-gray-400 border border-gray-800 text-xs"
  defp message_style(:tool), do: "bg-gray-900 text-gray-400 font-mono text-xs"
  defp message_style(_), do: "bg-gray-800 text-gray-300"

  defp status_dot_class(:pending), do: "bg-gray-500"
  defp status_dot_class(:running), do: "bg-yellow-500 animate-pulse"
  defp status_dot_class(:complete), do: "bg-green-500"
  defp status_dot_class(:error), do: "bg-red-500"

  defp status_badge_variant(:error), do: "destructive"
  defp status_badge_variant(:complete), do: "default"
  defp status_badge_variant(_), do: "secondary"

  defp stage_badge_variant(:running), do: "default"
  defp stage_badge_variant(:complete), do: "outline"
  defp stage_badge_variant(:error), do: "destructive"
  defp stage_badge_variant(_), do: "secondary"
end
