defmodule Crew.Vault do
  @moduledoc """
  Encryption at rest for GitHub tokens, the App's credentials and
  stored keys (AES-256-GCM). The key comes from CREW_ENCRYPTION_KEY;
  CREW_ENCRYPTION_KEYS_RETIRED are older ones, still read until
  `Crew.Release.reencrypt/0` has moved everything to the current key.
  """
  use Cloak.Vault, otp_app: :crew

  @doc "Whether the current key, a retired one or `:none` of them encrypted a value."
  def which_key(ciphertext), do: Crew.Vault.Cipher.which_key(ciphertext, cipher_opts())

  @doc "IDs of the configured keys, current first. They don't reveal the keys."
  def key_ids, do: Enum.map(cipher_opts()[:keys], &key_id/1)

  def key_id(key) do
    :crypto.mac(:hmac, :sha256, key, "crew key id")
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  defp cipher_opts do
    {Crew.Vault.Cipher, opts} =
      Application.fetch_env!(:crew, __MODULE__)[:ciphers][:default]

    opts
  end

  @doc "Every schema with an encrypted field, and those fields."
  def encrypted_schemas do
    {:ok, modules} = :application.get_key(:crew, :modules)

    for module <- Enum.sort(modules),
        Code.ensure_loaded?(module),
        function_exported?(module, :__schema__, 1),
        module.__schema__(:source),
        fields = encrypted_fields(module),
        fields != [],
        do: {module, fields}
  end

  defp encrypted_fields(schema) do
    for field <- schema.__schema__(:fields),
        type = schema.__schema__(:type, field),
        is_atom(type) and Code.ensure_loaded?(type) and function_exported?(type, :__cloak__, 0),
        do: field
  end
end

defmodule Crew.Vault.Cipher do
  @moduledoc """
  `Cloak.Ciphers.AES.GCM` with retired keys: encrypts with the first of
  `:keys` and decrypts with whichever of them encrypted the value.

  Every value carries the same tag whatever the key, as everything stored
  before rotation existed does, so Cloak can't tell the keys apart by tag
  (it picks a cipher by tag alone). GCM authenticates, so trying each key
  in turn can't return the wrong plaintext.
  """
  @behaviour Cloak.Cipher

  alias Cloak.Ciphers.AES.GCM

  @impl true
  def encrypt(plaintext, opts) do
    [key | _] = Keyword.fetch!(opts, :keys)
    GCM.encrypt(plaintext, gcm_opts(opts, key))
  end

  @impl true
  def decrypt(ciphertext, opts) do
    case decrypt_with_keys(ciphertext, opts) do
      {:ok, _index, plaintext} -> {:ok, plaintext}
      :error -> :error
    end
  end

  @doc "`:current`, `:retired` or `:none`: which of `:keys` encrypted the value."
  def which_key(ciphertext, opts) do
    case decrypt_with_keys(ciphertext, opts) do
      {:ok, 0, _} -> :current
      {:ok, _, _} -> :retired
      :error -> :none
    end
  end

  # GCM.decrypt returns {:ok, :error} when the key is wrong.
  defp decrypt_with_keys(ciphertext, opts) do
    if can_decrypt?(ciphertext, opts) do
      opts
      |> Keyword.fetch!(:keys)
      |> Enum.with_index()
      |> Enum.find_value(:error, fn {key, index} ->
        case GCM.decrypt(ciphertext, gcm_opts(opts, key)) do
          {:ok, plaintext} when is_binary(plaintext) -> {:ok, index, plaintext}
          _ -> nil
        end
      end)
    else
      :error
    end
  end

  @impl true
  def can_decrypt?(ciphertext, opts), do: GCM.can_decrypt?(ciphertext, opts)

  defp gcm_opts(opts, key), do: opts |> Keyword.delete(:keys) |> Keyword.put(:key, key)
end

defmodule Crew.Encrypted.Binary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: Crew.Vault
end

defmodule Crew.Encrypted.Map do
  @moduledoc false
  use Cloak.Ecto.Map, vault: Crew.Vault
end
