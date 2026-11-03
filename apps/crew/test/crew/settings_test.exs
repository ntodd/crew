defmodule Crew.SettingsTest do
  use Crew.DataCase

  import ExUnit.CaptureLog

  alias Cloak.Ciphers.AES.GCM
  alias Crew.Settings

  defp keys do
    {Crew.Vault.Cipher, opts} =
      Application.fetch_env!(:crew, Crew.Vault)[:ciphers][:default]

    opts[:keys]
  end

  # A setting as another key would have stored it.
  defp put_raw(key, value, encryption_key) do
    {:ok, ciphertext} =
      GCM.encrypt(Jason.encode!(%{"v" => value}),
        tag: "AES.GCM.V1",
        key: encryption_key,
        iv_length: 12
      )

    now = NaiveDateTime.utc_now()

    Repo.insert_all("settings", [
      %{key: key, value: ciphertext, inserted_at: now, updated_at: now}
    ])
  end

  defp put_user_token(encryption_key) do
    user = user_fixture()

    {:ok, ciphertext} =
      GCM.encrypt("ghu_x", tag: "AES.GCM.V1", key: encryption_key, iv_length: 12)

    Repo.update_all(from(u in "users", where: u.id == type(^user.id, :binary_id)),
      set: [access_token: ciphertext]
    )
  end

  defp recorded_keys, do: Settings.get("encryption_key_check")["keys"]

  defp record_keys(keys), do: Settings.put("encryption_key_check", %{"keys" => keys})

  defp id(key), do: Crew.Vault.key_id(key)

  describe "check_encryption_key/0" do
    # Each test starts from the deployment state it describes.
    setup do
      Repo.delete_all(Settings.Setting)
      [current, retired | _] = keys()
      %{current: current, retired: retired, other: :crypto.strong_rand_bytes(32)}
    end

    test "is fine when the key reads everything stored" do
      Settings.put("github_app", %{"id" => 1})

      assert Settings.check_encryption_key() == :ok
    end

    test "fails, naming CREW_ENCRYPTION_KEY, when the key doesn't read a setting", keys do
      put_raw("github_app", %{"id" => 1}, keys.other)

      assert {:error, message} = Settings.check_encryption_key()
      assert message =~ "CREW_ENCRYPTION_KEY"
      assert message =~ "github_app"
      refute recorded_keys()
    end

    test "reads settings stored with a retired key", keys do
      put_raw("github_app", %{"id" => 1}, keys.retired)

      assert Settings.check_encryption_key() == :ok
      assert Settings.get("github_app") == %{"id" => 1}
    end

    # Encrypted data elsewhere (users' tokens, secrets) can exist with no
    # settings at all, when the GitHub App comes from the environment.
    test "the first time, records the key everything is under", keys do
      put_user_token(keys.current)

      assert Settings.check_encryption_key() == :ok
      assert recorded_keys() == [id(keys.current)]
    end

    test "the first time, checks encrypted data outside settings too", keys do
      put_user_token(keys.other)

      assert {:error, message} = Settings.check_encryption_key()
      assert message =~ "users.access_token"
      refute recorded_keys()
    end

    # Recording only the current key would let the retired one be dropped
    # before everything was re-encrypted.
    test "the first time, records the retired keys too while data is under one", keys do
      put_user_token(keys.retired)

      assert Settings.check_encryption_key() == :ok
      assert recorded_keys() == [id(keys.current), id(keys.retired)]
    end

    # Rotating: the new key goes in, with the old one retired. What's
    # written from now on is under the new key.
    test "adds the current key to those recorded", keys do
      record_keys([id(keys.retired)])

      assert Settings.check_encryption_key() == :ok
      assert recorded_keys() == [id(keys.retired), id(keys.current)]
    end

    # A retired key dropped before re-encrypting finished, or going back
    # to the old key after the new one wrote something.
    test "checks everything when a recorded key isn't configured", keys do
      record_keys([id(keys.current), id(keys.other)])
      put_user_token(keys.other)

      assert {:error, message} = Settings.check_encryption_key()
      assert message =~ "users.access_token"
      assert recorded_keys() == [id(keys.current), id(keys.other)]
    end

    test "after checking everything, records only the keys still needed", keys do
      record_keys([id(keys.current), id(keys.other)])
      put_user_token(keys.current)

      assert Settings.check_encryption_key() == :ok
      assert recorded_keys() == [id(keys.current)]
    end
  end

  describe "start_checking_encryption_key/0" do
    test "lets the boot go on when the key is right" do
      assert Settings.start_checking_encryption_key() == :ignore
    end

    # Crew.Setup would read the GitHub App and crash with a stack
    # trace that doesn't mention the key, over and over.
    test "stops the boot and logs why when the key is wrong" do
      put_raw("github_app", %{"id" => 1}, :crypto.strong_rand_bytes(32))

      log =
        capture_log(fn ->
          assert {:error, :wrong_encryption_key} = Settings.start_checking_encryption_key()
        end)

      assert log =~ "CREW_ENCRYPTION_KEY"
    end
  end
end
