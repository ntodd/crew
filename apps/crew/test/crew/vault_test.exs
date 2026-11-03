defmodule Crew.VaultTest do
  use ExUnit.Case, async: true

  alias Cloak.Ciphers.AES.GCM
  alias Crew.Vault.Cipher

  @current :crypto.strong_rand_bytes(32)
  @retired :crypto.strong_rand_bytes(32)
  @opts [tag: "AES.GCM.V1", keys: [@current, @retired], iv_length: 12]

  defp gcm(key), do: [tag: "AES.GCM.V1", key: key, iv_length: 12]

  test "encrypts with the current key" do
    {:ok, ciphertext} = Cipher.encrypt("hello", @opts)

    assert GCM.decrypt(ciphertext, gcm(@current)) == {:ok, "hello"}
    assert Cipher.decrypt(ciphertext, @opts) == {:ok, "hello"}
  end

  # Everything stored before there was more than one key.
  test "reads what Cloak's AES.GCM cipher wrote with the current key" do
    {:ok, ciphertext} = GCM.encrypt("hello", gcm(@current))

    assert Cipher.can_decrypt?(ciphertext, @opts)
    assert Cipher.decrypt(ciphertext, @opts) == {:ok, "hello"}
  end

  test "reads values encrypted with a retired key" do
    {:ok, ciphertext} = GCM.encrypt("hello", gcm(@retired))

    assert Cipher.decrypt(ciphertext, @opts) == {:ok, "hello"}
  end

  # Cloak's cipher returns {:ok, :error} here, which a binary field
  # loads as the atom :error and a map field passes to Jason.decode!.
  test "a value none of the keys encrypted is an error" do
    {:ok, ciphertext} = GCM.encrypt("hello", gcm(:crypto.strong_rand_bytes(32)))

    assert Cipher.decrypt(ciphertext, @opts) == :error
  end

  test "a value with another tag isn't this cipher's" do
    {:ok, ciphertext} = GCM.encrypt("hello", tag: "OTHER", key: @current, iv_length: 12)

    refute Cipher.can_decrypt?(ciphertext, @opts)
    assert Cipher.decrypt(ciphertext, @opts) == :error
  end

  test "says which key a value is under" do
    {:ok, current} = Cipher.encrypt("hello", @opts)
    {:ok, retired} = GCM.encrypt("hello", gcm(@retired))
    {:ok, unknown} = GCM.encrypt("hello", gcm(:crypto.strong_rand_bytes(32)))

    assert Cipher.which_key(current, @opts) == :current
    assert Cipher.which_key(retired, @opts) == :retired
    assert Cipher.which_key(unknown, @opts) == :none
  end
end
