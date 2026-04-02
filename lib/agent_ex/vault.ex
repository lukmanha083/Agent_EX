defmodule AgentEx.Vault do
  @moduledoc """
  Encrypted secrets storage per project.

  Secrets are encrypted at rest using AES-256-GCM. Values are only
  decrypted when explicitly read via `get_value/2`.

  ## Key naming convention
  - `llm:<provider>` — LLM API key (e.g. `llm:anthropic`, `llm:openai`)
  - `embedding:<provider>` — Embedding API key (e.g. `embedding:openai`)
  """

  import Ecto.Query

  alias AgentEx.Repo
  alias AgentEx.Vault.{Cipher, Secret}

  @doc "List all secrets for a project (values masked, not decrypted)."
  @spec list_secrets(integer()) :: [Secret.t()]
  def list_secrets(project_id) do
    Secret
    |> where(project_id: ^project_id)
    |> order_by(asc: :key)
    |> Repo.all()
    |> Enum.map(&mask_secret/1)
  end

  @doc "Get the decrypted value for a secret by project and key."
  @spec get_value(integer(), String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def get_value(project_id, key) do
    case Repo.get_by(Secret, project_id: project_id, key: key) do
      nil ->
        :not_found

      %Secret{encrypted_value: encrypted} ->
        Cipher.decrypt(encrypted)
    end
  end

  @doc "Set (upsert) a secret. Encrypts the value before storing."
  @spec set_secret(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Secret.t()} | {:error, term()}
  def set_secret(project_id, key, value, label \\ nil) do
    with {:ok, encrypted} <- Cipher.encrypt(value) do
      attrs = %{
        project_id: project_id,
        key: key,
        encrypted_value: encrypted,
        label: label
      }

      case Repo.get_by(Secret, project_id: project_id, key: key) do
        nil ->
          %Secret{}
          |> Secret.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> Secret.changeset(attrs)
          |> Repo.update()
      end
    end
  end

  @doc "Delete a secret."
  @spec delete_secret(integer(), String.t()) :: :ok | :not_found
  def delete_secret(project_id, key) do
    case Repo.get_by(Secret, project_id: project_id, key: key) do
      nil ->
        :not_found

      secret ->
        case Repo.delete(secret) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Resolve an API key from the vault, falling back to app config then env var.

  Used by ModelClient and Embeddings to get the appropriate key.
  """
  @spec resolve_key(integer() | nil, String.t(), atom(), String.t()) :: String.t()
  def resolve_key(project_id, vault_key, app_config_key, env_var) do
    vault_value =
      if project_id do
        case get_value(project_id, vault_key) do
          {:ok, value} when value != "" -> value
          _ -> nil
        end
      end

    vault_value ||
      Application.get_env(:agent_ex, app_config_key) ||
      System.get_env(env_var) ||
      ""
  end

  # Mask the value for display — show first 4 chars + ****
  defp mask_secret(%Secret{encrypted_value: encrypted} = secret) do
    masked =
      case Cipher.decrypt(encrypted) do
        {:ok, value} when byte_size(value) > 4 ->
          String.slice(value, 0, 4) <> String.duplicate("*", 8)

        {:ok, _} ->
          "****"

        _ ->
          "****"
      end

    %{secret | value: masked}
  end
end
