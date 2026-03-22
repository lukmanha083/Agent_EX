defmodule AgentExWeb.UserLive.Confirmation do
  use AgentExWeb, :live_view

  alias AgentEx.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col lg:flex-row min-h-screen bg-gray-950">
      <%!-- Left panel: logo --%>
      <div class="flex items-center justify-center bg-gray-950 p-8 lg:w-1/2 lg:p-16 border-b lg:border-b-0 lg:border-r border-gray-800">
        <img
          src={~p"/images/logo.svg"}
          alt="AgentEx"
          class="w-64 md:w-80 lg:w-[420px]"
        />
      </div>

      <%!-- Right panel: confirmation --%>
      <div class="flex flex-1 flex-col items-center justify-center bg-gray-900 p-6 md:p-12 lg:w-1/2">
        <div class="w-full max-w-sm space-y-6">
          <.flash_group flash={@flash} />

          <div>
            <h1 class="text-2xl font-bold text-white">Welcome</h1>
            <p class="mt-1 text-sm text-gray-400">{@user.email}</p>
          </div>

          <.form
            :if={!@user.confirmed_at}
            for={@form}
            id="confirmation_form"
            phx-mounted={JS.focus_first()}
            phx-submit="submit"
            action={~p"/users/log-in?_action=confirmed"}
            phx-trigger-action={@trigger_submit}
            class="space-y-3"
          >
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Confirming..."
              class="w-full bg-indigo-600 hover:bg-indigo-500 text-white"
            >
              Confirm and stay signed in
            </.button>
            <.button
              phx-disable-with="Confirming..."
              class="w-full bg-gray-800 hover:bg-gray-700 text-gray-300 border border-gray-700"
            >
              Confirm and sign in only this time
            </.button>
          </.form>

          <.form
            :if={@user.confirmed_at}
            for={@form}
            id="login_form"
            phx-submit="submit"
            phx-mounted={JS.focus_first()}
            action={~p"/users/log-in"}
            phx-trigger-action={@trigger_submit}
            class="space-y-3"
          >
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <%= if @current_scope do %>
              <.button phx-disable-with="Signing in..." class="w-full bg-indigo-600 hover:bg-indigo-500 text-white">
                Sign in
              </.button>
            <% else %>
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with="Signing in..."
                class="w-full bg-indigo-600 hover:bg-indigo-500 text-white"
              >
                Stay signed in on this device
              </.button>
              <.button
                phx-disable-with="Signing in..."
                class="w-full bg-gray-800 hover:bg-gray-700 text-gray-300 border border-gray-700"
              >
                Sign in only this time
              </.button>
            <% end %>
          </.form>

          <p :if={!@user.confirmed_at} class="text-sm text-gray-500">
            Tip: If you prefer passwords, you can enable them in the user settings.
          </p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil], layout: false}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
