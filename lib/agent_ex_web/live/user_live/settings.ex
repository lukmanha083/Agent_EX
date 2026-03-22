defmodule AgentExWeb.UserLive.Settings do
  use AgentExWeb, :live_view

  on_mount({AgentExWeb.UserAuth, :require_sudo_mode})

  alias AgentEx.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6 md:p-10">
      <div class="mx-auto max-w-lg space-y-8">
        <%!-- Profile header with avatar --%>
        <div class="flex items-center gap-4">
          <div class="flex h-16 w-16 items-center justify-center rounded-full bg-indigo-600 text-xl font-bold text-white">
            {initials(@current_scope.user.username || @current_scope.user.email)}
          </div>
          <div>
            <h1 class="text-2xl font-bold text-white">{@current_scope.user.username || @current_scope.user.email}</h1>
            <p class="text-sm text-gray-400">{@current_scope.user.email}</p>
          </div>
        </div>

        <%!-- Username section --%>
        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6 space-y-4">
          <h2 class="text-lg font-semibold text-white">Username</h2>
          <.form for={@username_form} id="username_form" phx-submit="update_username" phx-change="validate_username" class="space-y-4">
            <.input
              field={@username_form[:username]}
              type="text"
              label="Username"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button phx-disable-with="Saving..." class="bg-indigo-600 hover:bg-indigo-500 text-white">
              Update username
            </.button>
          </.form>
        </div>

        <%!-- Email section --%>
        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6 space-y-4">
          <h2 class="text-lg font-semibold text-white">Email address</h2>
          <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email" class="space-y-4">
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              spellcheck="false"
              required
            />
            <.button phx-disable-with="Changing..." class="bg-indigo-600 hover:bg-indigo-500 text-white">
              Change email
            </.button>
          </.form>
        </div>

        <%!-- Password section --%>
        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6 space-y-4">
          <h2 class="text-lg font-semibold text-white">Password</h2>
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-4"
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              spellcheck="false"
              value={@current_email}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              spellcheck="false"
            />
            <.button phx-disable-with="Saving..." class="bg-indigo-600 hover:bg-indigo-500 text-white">
              Save password
            </.button>
          </.form>
        </div>

        <%!-- Sign out --%>
        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6">
          <.link href={~p"/users/log-out"} method="delete" class="flex items-center gap-2 text-sm text-red-400 hover:text-red-300 transition-colors">
            <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
            Sign out of your account
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    username_changeset = Accounts.change_user_username(user, %{})
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:username_form, to_form(username_changeset))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_username", params, socket) do
    %{"user" => user_params} = params

    username_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_username(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, username_form: username_form)}
  end

  def handle_event("update_username", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.update_user_username(user, user_params) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Username updated successfully.")
           |> push_navigate(to: ~p"/users/settings")}

        {:error, changeset} ->
          {:noreply, assign(socket, username_form: to_form(changeset, action: :insert))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Session expired. Please re-authenticate.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.change_user_email(user, user_params) do
        %{valid?: true} = changeset ->
          Accounts.deliver_user_update_email_instructions(
            Ecto.Changeset.apply_action!(changeset, :insert),
            user.email,
            &url(~p"/users/settings/confirm-email/#{&1}")
          )

          info = "A link to confirm your email change has been sent to the new address."
          {:noreply, socket |> put_flash(:info, info)}

        changeset ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Session expired. Please re-authenticate.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.change_user_password(user, user_params) do
        %{valid?: true} = changeset ->
          {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

        changeset ->
          {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Session expired. Please re-authenticate.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  defp initials(username) when is_binary(username) do
    username
    |> String.split("_")
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp initials(_), do: "?"
end
