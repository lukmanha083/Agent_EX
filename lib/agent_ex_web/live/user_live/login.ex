defmodule AgentExWeb.UserLive.Login do
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

      <%!-- Right panel: sign-in form --%>
      <div class="flex flex-1 flex-col items-center justify-center bg-gray-900 p-6 md:p-12 lg:w-1/2">
        <div class="w-full max-w-sm space-y-6">
          <.flash_group flash={@flash} />

          <div>
            <h1 class="text-2xl font-bold text-white">Sign in</h1>
            <p :if={@current_scope} class="mt-1 text-sm text-gray-400">
              Re-authenticate to perform sensitive actions on your account.
            </p>
          </div>

          <div :if={local_mail_adapter?()} class="rounded-lg border border-gray-700 bg-gray-800 p-3 text-sm text-gray-300">
            <div class="flex items-start gap-2">
              <.icon name="hero-information-circle" class="mt-0.5 h-5 w-5 shrink-0 text-indigo-400" />
              <p>
                Local mail adapter is active.
                <.link href="/dev/mailbox" class="underline hover:text-white">View mailbox</.link>
              </p>
            </div>
          </div>

          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
            class="space-y-4"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button class="w-full bg-indigo-600 hover:bg-indigo-500 text-white">
              Sign in with email <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <div class="flex items-center gap-3">
            <div class="h-px flex-1 bg-gray-800"></div>
            <span class="text-xs text-gray-500">or</span>
            <div class="h-px flex-1 bg-gray-800"></div>
          </div>

          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-4"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="w-full bg-indigo-600 hover:bg-indigo-500 text-white" name={@form[:remember_me].name} value="true">
              Sign in <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <p :if={!@current_scope} class="text-center text-sm text-gray-400">
            Don't have an account?
            <.link navigate={~p"/users/register"} class="font-semibold text-indigo-400 hover:text-indigo-300">
              Sign up
            </.link>
          </p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false), layout: false}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:agent_ex, :dev_routes, false) &&
      Application.get_env(:agent_ex, AgentEx.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
