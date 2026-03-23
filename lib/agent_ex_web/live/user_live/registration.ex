defmodule AgentExWeb.UserLive.Registration do
  use AgentExWeb, :live_view

  alias AgentEx.Accounts
  alias AgentEx.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_page flash={@flash}>
      <div>
        <h1 class="text-2xl font-bold text-white">Create an account</h1>
      </div>

      <.form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-hook="TimezoneDetect"
        class="space-y-4"
      >
        <.input
          field={@form[:username]}
          type="text"
          label="Username"
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          autocomplete="email"
          spellcheck="false"
          required
        />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="new-password"
          required
        />
        <.input
          field={@form[:timezone]}
          type="select"
          label="Timezone"
          options={@timezone_options}
        />

        <.button phx-disable-with="Creating account..." class="w-full bg-indigo-600 hover:bg-indigo-500 text-white">
          Sign up <span aria-hidden="true">→</span>
        </.button>
      </.form>

      <p class="text-center text-sm text-gray-400">
        Already have an account?
        <.link navigate={~p"/users/log-in"} class="font-semibold text-indigo-400 hover:text-indigo-300">
          Sign in
        </.link>
      </p>
    </.auth_page>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: AgentExWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset =
      Accounts.change_user_registration(%User{}, %{},
        validate_unique: false,
        hash_password: false
      )

    socket =
      socket
      |> assign(:timezone_options, AgentEx.Timezone.select_options())
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil], layout: false}
  end

  @impl true
  def handle_event("timezone_detected", %{"timezone" => tz}, socket) do
    if AgentEx.Timezone.valid?(tz) do
      existing_params = socket.assigns.form.params || %{}
      attrs = Map.put(existing_params, "timezone", tz)

      changeset =
        Accounts.change_user_registration(%User{}, attrs,
          validate_unique: false,
          hash_password: false
        )

      {:noreply, assign_form(socket, changeset)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_user_registration(%User{}, user_params,
        validate_unique: false,
        hash_password: false
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
