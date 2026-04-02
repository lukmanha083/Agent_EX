defmodule AgentEx.Vault.Cipher do
  @moduledoc """
  AES-256-GCM encryption for vault secrets.
  Uses a server-side key from application config.
  """

  @aad "AgentExVault"

  @doc "Encrypt a plaintext value. Returns `{:ok, ciphertext}` or `{:error, reason}`."
  @spec encrypt(String.t()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext) when is_binary(plaintext) do
    key = vault_key!()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    # Pack as: iv (12) + tag (16) + ciphertext
    {:ok, iv <> tag <> ciphertext}
  rescue
    e -> {:error, {:encrypt_failed, Exception.message(e)}}
  end

  @doc "Decrypt a ciphertext. Returns `{:ok, plaintext}` or `{:error, reason}`."
  @spec decrypt(binary()) :: {:ok, String.t()} | {:error, term()}
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = vault_key!()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :decrypt_failed}
      plaintext -> {:ok, plaintext}
    end
  rescue
    e -> {:error, {:decrypt_failed, Exception.message(e)}}
  end

  def decrypt(_), do: {:error, :invalid_ciphertext}

  defp vault_key! do
    case Application.get_env(:agent_ex, :vault_key) do
      nil ->
        raise "Missing :vault_key in config. Set config :agent_ex, :vault_key to a 32-byte base64-encoded key."

      base64_key ->
        case Base.decode64(base64_key) do
          {:ok, <<key::binary-32>>} -> key
          _ -> raise "Invalid :vault_key — must be exactly 32 bytes (base64-encoded)"
        end
    end
  end
end
