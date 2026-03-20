defmodule AgentExWeb.ChatComponents do
  @moduledoc """
  Components for the chat interface — message bubbles, tool cards,
  thinking indicators, and event timeline.
  """

  use Phoenix.Component

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
        <%= role_icon(@role) %>
      </div>

      <div class={[
        "max-w-[75%] rounded-xl px-4 py-2.5 text-sm leading-relaxed",
        message_style(@role)
      ]}>
        <p :if={@source && @role == :assistant} class="text-xs text-gray-500 mb-1">
          <%= @source %>
        </p>
        <div class="whitespace-pre-wrap break-words"><%= @content %></div>
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
    <div class="mx-4 my-2 rounded-lg border border-gray-800 bg-gray-900/50 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-2 border-b border-gray-800">
        <span class={[
          "w-2 h-2 rounded-full",
          @status == :pending && "bg-gray-500",
          @status == :running && "bg-yellow-500 animate-pulse",
          @status == :complete && "bg-green-500",
          @status == :error && "bg-red-500"
        ]} />
        <span class="text-xs font-mono text-gray-400"><%= @name %></span>
        <span class="text-xs text-gray-600 ml-auto"><%= @status %></span>
      </div>

      <div :if={@arguments} class="px-3 py-2 border-b border-gray-800">
        <p class="text-xs text-gray-600 mb-1">Arguments</p>
        <pre class="text-xs text-gray-400 font-mono overflow-x-auto"><%= @arguments %></pre>
      </div>

      <div :if={@result} class="px-3 py-2">
        <p class="text-xs text-gray-600 mb-1">Result</p>
        <pre class={[
          "text-xs font-mono overflow-x-auto",
          @status == :error && "text-red-400" || "text-gray-400"
        ]}><%= @result %></pre>
      </div>
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
    <div :if={@stages != []} class="flex items-center gap-1 px-4 py-2 overflow-x-auto">
      <div :for={{stage, idx} <- Enum.with_index(@stages)} class="flex items-center gap-1">
        <span :if={idx > 0} class="w-4 h-px bg-gray-700" />
        <span class={[
          "px-2 py-0.5 rounded text-xs font-mono",
          stage.status == :running && "bg-indigo-900/50 text-indigo-400 border border-indigo-700",
          stage.status == :complete && "bg-green-900/50 text-green-400 border border-green-800",
          stage.status == :pending && "bg-gray-900 text-gray-500 border border-gray-800",
          stage.status == :error && "bg-red-900/50 text-red-400 border border-red-800"
        ]}>
          <%= stage.name %>
        </span>
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
end
