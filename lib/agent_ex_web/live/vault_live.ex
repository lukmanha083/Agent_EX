defmodule AgentExWeb.VaultLive do
  use AgentExWeb, :live_view

  alias AgentEx.Vault

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <header class="flex items-center justify-between px-4 md:px-6 h-14 border-b border-gray-800 bg-gray-900/50 shrink-0">
        <div>
          <h1 class="text-base font-semibold text-white">Vault</h1>
          <p class="text-xs text-gray-500">
            <span class="text-indigo-400">{@project.name}</span>
            <span> — </span>Manage API keys and secrets
          </p>
        </div>
      </header>

      <div class="flex-1 overflow-y-auto p-4 md:p-6">
        <div class="mx-auto max-w-2xl space-y-6">
          <%!-- Add secret form --%>
          <div class="rounded-lg border border-gray-800 bg-gray-900 p-4">
            <h2 class="text-sm font-medium text-white mb-3">Add Secret</h2>
            <.form for={@form} phx-submit="save_secret" class="space-y-3" id={"secret-form-#{@form_key}"}>
              <div class="grid grid-cols-2 gap-3">
                <.input type="select" name="key" value={@form["key"]} label="Key" options={key_options()} id={"secret-key-#{@form_key}"} />
                <.input type="text" name="label" value={@form["label"]} label="Label (optional)" placeholder="e.g. Production key" id={"secret-label-#{@form_key}"} />
              </div>
              <.input type="password" name="value" value="" label="Value" placeholder="sk-..." required autocomplete="off" id={"secret-value-#{@form_key}"} />
              <p class="text-[10px] text-gray-500">
                Values are encrypted at rest (AES-256-GCM). You cannot view the full value after saving.
              </p>
              <.button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white">
                Save Secret
              </.button>
            </.form>
          </div>

          <%!-- Secrets list --%>
          <div class="space-y-2">
            <h2 class="text-sm font-medium text-white">Stored Secrets</h2>

            <%= if @secrets == [] do %>
              <p class="text-sm text-gray-500 py-4 text-center">No secrets stored yet.</p>
            <% else %>
              <div :for={secret <- @secrets} class="flex items-center justify-between rounded-lg border border-gray-800 bg-gray-900 px-4 py-3">
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-mono text-indigo-400">{secret.key}</span>
                    <span :if={secret.label} class="text-xs text-gray-500">{secret.label}</span>
                  </div>
                  <p class="text-xs font-mono text-gray-600 mt-0.5">{secret.value}</p>
                </div>
                <button
                  type="button"
                  phx-click="delete_secret"
                  phx-value-key={secret.key}
                  data-confirm={"Delete secret '#{secret.key}'? This cannot be undone."}
                  class="p-1.5 rounded-md text-gray-400 hover:text-red-400 hover:bg-gray-800 transition-colors shrink-0"
                  aria-label={"Delete #{secret.key}"}
                >
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5">
                    <path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd" />
                  </svg>
                </button>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    project = socket.assigns.current_project

    {:ok,
     assign(socket,
       project: project,
       secrets: Vault.list_secrets(project.id),
       form: empty_form(),
       form_key: System.unique_integer()
     )}
  end

  @impl true
  def handle_event("save_secret", params, socket) do
    project = socket.assigns.project
    key = params["key"]
    value = params["value"]
    label = blank_to_nil(params["label"])

    if value == "" or is_nil(value) do
      {:noreply, put_flash(socket, :error, "Value cannot be empty")}
    else
      case Vault.set_secret(project.id, key, value, label) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             secrets: Vault.list_secrets(project.id),
             form: empty_form(),
             form_key: System.unique_integer()
           )
           |> put_flash(:info, "Secret '#{key}' saved")}

        {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
          {:noreply, put_flash(socket, :error, "Failed to save: invalid key format")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("delete_secret", %{"key" => key}, socket) do
    project = socket.assigns.project

    case Vault.delete_secret(project.id, key) do
      :ok ->
        {:noreply,
         socket
         |> assign(secrets: Vault.list_secrets(project.id))
         |> put_flash(:info, "Secret '#{key}' deleted")}

      :not_found ->
        {:noreply, put_flash(socket, :error, "Secret not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete secret")}
    end
  end

  defp empty_form do
    %{"key" => "llm:anthropic", "label" => "", "value" => ""}
  end

  defp key_options do
    [
      {"llm:anthropic", "LLM: Anthropic"},
      {"llm:openai", "LLM: OpenAI"},
      {"llm:moonshot", "LLM: Moonshot"},
      {"embedding:openai", "Embedding: OpenAI"}
    ]
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
