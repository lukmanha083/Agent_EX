defmodule AgentExWeb.UserLive.Settings do
  use AgentExWeb, :live_view

  on_mount({AgentExWeb.UserAuth, :require_sudo_mode})

  alias AgentEx.{Accounts, ProviderTools}
  import AgentExWeb.ProviderHelpers

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
              <p class="text-xs text-muted-foreground">API key configuration coming in a future update. Keys are currently read from server environment.</p>
              <.button phx-disable-with="Saving..." class="bg-indigo-600 hover:bg-indigo-500 text-white">
                Update provider
              </.button>
            </.form>
          </.card_content>
        </.card>

        <%!-- Provider Built-in Tools section --%>
        <.card :if={ProviderTools.has_builtins?(@selected_provider)}>
          <.card_header>
            <.card_title>Provider Tools</.card_title>
            <.card_description>
              Built-in tools provided by {@selected_provider}. These are available to the chat orchestrator.
            </.card_description>
          </.card_header>
          <.card_content>
            <div class="space-y-2">
              <div
                :for={spec <- ProviderTools.list(@selected_provider)}
                class="flex items-center justify-between rounded-md border border-gray-800 bg-gray-800/50 px-3 py-2"
              >
                <div>
                  <span class="text-sm font-medium text-white">{spec.name}</span>
                  <p class="text-xs text-gray-400">{spec.description}</p>
                </div>
                <button
                  type="button"
                  phx-click={if spec.name in @disabled_builtins, do: "enable_builtin", else: "disable_builtin"}
                  phx-value-name={spec.name}
                  class="relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500"
                  style={if spec.name in @disabled_builtins, do: "background-color: rgb(55, 65, 81)", else: "background-color: rgb(79, 70, 229)"}
                  role="switch"
                  aria-checked={to_string(spec.name not in @disabled_builtins)}
                  aria-label={"Toggle #{spec.name}"}
                >
                  <span
                    class="pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition-transform"
                    style={if spec.name in @disabled_builtins, do: "transform: translateX(0)", else: "transform: translateX(1rem)"}
                  />
                </button>
              </div>
            </div>
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
    provider_changeset = Accounts.change_user_provider(user, %{})
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:timezone_form, to_form(timezone_changeset))
      |> assign(:timezone_options, AgentEx.Timezone.select_options())
      |> assign(:provider_form, to_form(provider_changeset))
      |> assign(:selected_provider, user.provider || "openai")
      |> assign(:disabled_builtins, user.disabled_builtins || [])
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

  def handle_event("validate_provider", params, socket) do
    %{"user" => user_params} = params
    new_provider = user_params["provider"] || socket.assigns.selected_provider

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

    {:noreply, assign(socket, provider_form: provider_form, selected_provider: new_provider)}
  end

  def handle_event("update_provider", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      # Reset disabled_builtins when provider changes (old names may not apply)
      new_provider = user_params["provider"]
      provider_changed? = new_provider && new_provider != user.provider

      user_params =
        if provider_changed?,
          do: Map.put(user_params, "disabled_builtins", []),
          else: user_params

      case Accounts.update_user_provider(user, user_params) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Provider updated successfully.")
           |> push_navigate(to: ~p"/users/settings")}

        {:error, changeset} ->
          provider =
            Ecto.Changeset.get_field(changeset, :provider) || socket.assigns.selected_provider

          {:noreply,
           assign(socket,
             provider_form: to_form(changeset, action: :insert),
             selected_provider: provider
           )}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Session expired. Please re-authenticate.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  def handle_event("disable_builtin", %{"name" => name}, socket) do
    disabled = Enum.uniq([name | socket.assigns.disabled_builtins])
    user = socket.assigns.current_scope.user

    case Accounts.update_user_disabled_builtins(user, disabled) do
      {:ok, _} -> {:noreply, assign(socket, disabled_builtins: disabled)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update")}
    end
  end

  def handle_event("enable_builtin", %{"name" => name}, socket) do
    disabled = Enum.reject(socket.assigns.disabled_builtins, &(&1 == name))
    user = socket.assigns.current_scope.user

    case Accounts.update_user_disabled_builtins(user, disabled) do
      {:ok, _} -> {:noreply, assign(socket, disabled_builtins: disabled)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update")}
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
