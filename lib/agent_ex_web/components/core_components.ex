defmodule AgentExWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the AgentEx web interface.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: AgentExWeb.Endpoint,
    router: AgentExWeb.Router,
    statics: AgentExWeb.static_paths()

  alias Phoenix.LiveView.JS

  @doc """
  Renders a header with title and optional subtitle.
  """
  slot(:inner_block, required: true)
  slot(:subtitle)
  slot(:actions)

  def header(assigns) do
    ~H"""
    <header class="mb-6">
      <h1 class="text-xl font-bold text-white">
        <%= render_slot(@inner_block) %>
      </h1>
      <p :for={subtitle <- @subtitle} class="mt-1 text-sm text-gray-400">
        <%= render_slot(subtitle) %>
      </p>
      <div :for={action <- @actions} class="mt-4">
        <%= render_slot(action) %>
      </div>
    </header>
    """
  end

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
  attr(:variant, :string, default: nil)
  attr(:rest, :global, include: ~w(disabled form name value))

  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "phx-submit-loading:opacity-75 rounded-lg px-3 py-2",
        "text-sm font-semibold transition-colors disabled:opacity-50 disabled:cursor-not-allowed",
        button_variant_class(@variant),
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  defp button_variant_class("primary"), do: "bg-indigo-600 text-white hover:bg-indigo-500"
  defp button_variant_class(_), do: "bg-indigo-600 text-white hover:bg-indigo-500"

  @doc """
  Renders a form-aware input with label and error messages.

  For simple non-form inputs, use a plain HTML `<input>` tag.
  """
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any)
  attr(:type, :string, default: "text")
  attr(:field, Phoenix.HTML.FormField, doc: "a form field struct")
  attr(:errors, :list, default: [])
  attr(:class, :string, default: nil)
  attr(:options, :list, default: nil, doc: "options for select type")
  attr(:rest, :global, include: ~w(autocomplete disabled form placeholder readonly required))

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> assign_new(:label, fn -> Phoenix.Naming.humanize(field.field) end)
    |> input()
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-300 mb-1">
        {@label}
      </label>
      <select
        name={@name}
        id={@id}
        class={[
          "block w-full rounded-lg bg-gray-800 border border-gray-700 text-white",
          "focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500",
          "text-sm px-3 py-2",
          @errors != [] && "border-red-500",
          @class
        ]}
        {@rest}
      >
        <option :for={opt <- @options || []} value={option_value(opt)} selected={option_value(opt) == to_string(@value)}>
          {option_label(opt)}
        </option>
      </select>
      <p :for={msg <- @errors} class="mt-1 text-xs text-red-400">{msg}</p>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-300 mb-1">
        {@label}
      </label>
      <textarea
        name={@name}
        id={@id}
        class={[
          "block w-full rounded-lg bg-gray-800 border border-gray-700 text-white",
          "placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500",
          "text-sm px-3 py-2 resize-none min-h-[100px]",
          @errors != [] && "border-red-500",
          @class
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      <p :for={msg <- @errors} class="mt-1 text-xs text-red-400">{msg}</p>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-300 mb-1">
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "block w-full rounded-lg bg-gray-800 border border-gray-700 text-white",
          "placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500",
          "text-sm px-3 py-2",
          @errors != [] && "border-red-500",
          @class
        ]}
        {@rest}
      />
      <p :for={msg <- @errors} class="mt-1 text-xs text-red-400">{msg}</p>
    </div>
    """
  end

  defp option_value({value, _label}), do: to_string(value)
  defp option_value(value), do: to_string(value)

  defp option_label({_value, label}), do: label
  defp option_label(value), do: to_string(value)

  @doc """
  Renders a hero icon by name. Requires heroicons to be available.
  Falls back to an empty span if icon is not found.
  """
  attr(:name, :string, required: true)
  attr(:class, :string, default: nil)

  def icon(assigns) do
    ~H"""
    <span class={["hero-icon", @name, @class]} />
    """
  end

  @doc """
  Renders the split-panel auth page shell with logo on the left and content on the right.
  """
  attr(:flash, :map, required: true)
  slot(:inner_block, required: true)

  def auth_page(assigns) do
    ~H"""
    <div class="flex flex-col lg:flex-row min-h-screen bg-gray-950">
      <div class="flex items-center justify-center bg-gray-950 p-8 lg:w-1/2 lg:p-16 border-b lg:border-b-0 lg:border-r border-gray-800">
        <img
          src={~p"/images/logo.svg"}
          alt="AgentEx"
          class="w-64 md:w-80 lg:w-[420px]"
        />
      </div>

      <div class="flex flex-1 flex-col items-center justify-center bg-gray-900 p-6 md:p-12 lg:w-1/2">
        <div class="w-full max-w-sm space-y-6">
          <.flash_group flash={@flash} />
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
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

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
