defmodule AgentExWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the AgentEx web interface.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages")
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global)

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 mr-2 w-80 rounded-lg p-3 ring-1 shadow-md",
        @kind == :info && "bg-emerald-50 text-emerald-800 ring-emerald-500/20",
        @kind == :error && "bg-rose-50 text-rose-800 ring-rose-500/20"
      ]}
      {@rest}
    >
      <p class="text-sm font-medium"><%= msg %></p>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard flash kinds.
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} flash={@flash} />
    <.flash kind={:error} flash={@flash} />
    """
  end

  @doc """
  Renders a button.
  """
  attr(:type, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(disabled form name value))

  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "phx-submit-loading:opacity-75 rounded-lg bg-indigo-600 px-3 py-2",
        "text-sm font-semibold text-white hover:bg-indigo-500 active:bg-indigo-700",
        "transition-colors disabled:opacity-50 disabled:cursor-not-allowed",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Renders a simple text input.
  """
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:value, :any)
  attr(:type, :string, default: "text")
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(autocomplete disabled form placeholder readonly required))

  def input(assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      id={@id}
      value={Phoenix.HTML.Form.normalize_value(@type, @value)}
      class={[
        "block w-full rounded-lg bg-gray-800 border border-gray-700 text-white",
        "placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500",
        "text-sm px-3 py-2",
        @class
      ]}
      {@rest}
    />
    """
  end

  ## JS Commands

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
