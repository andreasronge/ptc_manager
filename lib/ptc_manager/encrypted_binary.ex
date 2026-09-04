defmodule PtcManager.EncryptedBinary do
  @moduledoc false

  use Ecto.Type

  @aad "ptc-manager:agent-environment-variable:v1"
  @version 1
  @nonce_bytes 12
  @tag_bytes 16

  def type, do: :binary

  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  def dump(value) when is_binary(value) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, value, @aad, true)

    {:ok, <<@version, nonce::binary, tag::binary, ciphertext::binary>>}
  end

  def dump(_value), do: :error

  def load(
        <<@version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      ) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def load(_value), do: :error

  defp key do
    secret =
      Application.get_env(:ptc_manager, :resource_operation_secret) ||
        PtcManagerWeb.Endpoint.config(:secret_key_base)

    :crypto.hash(:sha256, [@aad, 0, secret])
  end
end
