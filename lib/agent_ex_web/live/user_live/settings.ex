defmodule AgentExWeb.UserLive.Settings do
  use AgentExWeb, :live_view

  on_mount({AgentExWeb.UserAuth, :require_sudo_mode})

  alias AgentEx.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-4 md:p-6 lg:p-10">
      <div class="mx-auto max-w-lg space-y-6">
        <h1 class="text-2xl font-bold text-white">Settings</h1>

        <.separator />

        <%!-- Timezone section --%>
        <.card>
          <.card_header>
            <.card_title>Timezone</.card_title>
          </.card_header>
          <.card_content>
            <.form for={@timezone_form} id="timezone_form" phx-submit="update_timezone" phx-change="validate_timezone" class="space-y-4">
              <.input
                field={@timezone_form[:timezone]}
                type="select"
                label="Timezone"
                options={@timezone_options}
              />
              <.button phx-disable-with="Saving..." class="bg-indigo-600 hover:bg-indigo-500 text-white">
                Update timezone
              </.button>
            </.form>
          </.card_content>
        </.card>

        <%!-- Password section --%>
        <.card>
          <.card_header>
            <.card_title>Password</.card_title>
          </.card_header>
          <.card_content>
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
          </.card_content>
        </.card>

        <%!-- Sign out --%>
        <.card>
          <.card_content class="py-4">
            <.link href={~p"/users/log-out"} method="delete" class="flex items-center gap-2 text-sm text-red-400 hover:text-red-300 transition-colors">
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              Sign out of your account
            </.link>
          </.card_content>
        </.card>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    timezone_changeset = Accounts.change_user_timezone(user, %{})
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:timezone_form, to_form(timezone_changeset))
      |> assign(:timezone_options, AgentEx.Timezone.select_options())
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_timezone", params, socket) do
    %{"user" => user_params} = params

    timezone_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_timezone(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, timezone_form: timezone_form)}
  end

  def handle_event("update_timezone", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.update_user_timezone(user, user_params) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Timezone updated successfully.")
           |> push_navigate(to: ~p"/users/settings")}

        {:error, changeset} ->
          {:noreply, assign(socket, timezone_form: to_form(changeset, action: :insert))}
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
end
