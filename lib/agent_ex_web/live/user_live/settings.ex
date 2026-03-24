defmodule AgentExWeb.UserLive.Settings do
  use AgentExWeb, :live_view

  on_mount({AgentExWeb.UserAuth, :require_sudo_mode})

  alias AgentEx.Accounts
  import AgentExWeb.ProviderHelpers

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-4 md:p-6 lg:p-10">
      <div class="mx-auto max-w-lg space-y-6">
        <%!-- Profile header with avatar --%>
        <div class="flex items-center gap-4">
          <div class="flex h-16 w-16 items-center justify-center rounded-full bg-indigo-600 text-xl font-bold text-white shrink-0">
            {initials(@current_scope.user.username || @current_scope.user.email)}
          </div>
          <div class="min-w-0">
            <h1 class="text-2xl font-bold text-white truncate">{@current_scope.user.username || @current_scope.user.email}</h1>
            <p class="text-sm text-gray-400 truncate">{@current_scope.user.email}</p>
          </div>
        </div>

        <.separator />

        <%!-- Username section --%>
        <.card>
          <.card_header>
            <.card_title>Username</.card_title>
          </.card_header>
          <.card_content>
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
          </.card_content>
        </.card>

        <%!-- Email section --%>
        <.card>
          <.card_header>
            <.card_title>Email address</.card_title>
          </.card_header>
          <.card_content>
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
          </.card_content>
        </.card>

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

        <%!-- LLM Provider section --%>
        <.card>
          <.card_header>
            <.card_title>LLM Provider</.card_title>
            <.card_description>Choose your default model for chat conversations.</.card_description>
          </.card_header>
          <.card_content>
            <.form for={@provider_form} id="provider_form" phx-submit="update_provider" phx-change="validate_provider" class="space-y-4">
              <.input
                field={@provider_form[:provider]}
                type="select"
                label="Provider"
                options={provider_options()}
              />
              <.input
                field={@provider_form[:model]}
                type="select"
                label="Model"
                options={Enum.map(models_for_provider(@selected_provider), fn m -> {m, m} end)}
              />
              <.input
                field={@provider_form[:provider_api_key]}
                type="password"
                label="API Key"
                placeholder="sk-..."
                autocomplete="off"
                disabled
              />
              <p class="text-xs text-muted-foreground">API key storage coming in a future update. Keys are currently read from server environment.</p>
              <.button phx-disable-with="Saving..." class="bg-indigo-600 hover:bg-indigo-500 text-white">
                Update provider
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
    timezone_changeset = Accounts.change_user_timezone(user, %{})
    provider_changeset = Accounts.change_user_provider(user, %{})
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:username_form, to_form(username_changeset))
      |> assign(:timezone_form, to_form(timezone_changeset))
      |> assign(:timezone_options, AgentEx.Timezone.select_options())
      |> assign(:provider_form, to_form(provider_changeset))
      |> assign(:selected_provider, user.provider || "openai")
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

  def handle_event("validate_provider", params, socket) do
    %{"user" => user_params} = params
    new_provider = user_params["provider"] || socket.assigns.selected_provider

    # Auto-set model to provider's default when provider changes
    user_params =
      if new_provider != socket.assigns.selected_provider do
        Map.put(user_params, "model", default_model_for(new_provider))
      else
        user_params
      end

    provider_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_provider(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket, provider_form: provider_form, selected_provider: new_provider)}
  end

  def handle_event("update_provider", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.update_user_provider(user, user_params) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Provider updated successfully.")
           |> push_navigate(to: ~p"/users/settings")}

        {:error, changeset} ->
          {:noreply, assign(socket, provider_form: to_form(changeset, action: :insert))}
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
