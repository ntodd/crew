defmodule Crew.RuntimeConfigTest do
  @moduledoc """
  Evaluates config/runtime.exs for :prod the way a release does, with the
  environment docs/setup/team.md gives the control plane.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @env %{
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "CREW_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
    "DATABASE_URL" => "ecto://user:pass@ep-example.us-east-2.aws.neon.tech/crew",
    "PHX_HOST" => "crew.tail1234.ts.net",
    "DATABASE_PATH" => "/var/lib/crew/crew.db"
  }

  setup do
    keys =
      Map.keys(@env) ++
        ["CREW_DB", "CREW_WEBHOOKS", "CREW_ENCRYPTION_KEYS_RETIRED"]

    saved_env = Map.new(keys, &{&1, System.get_env(&1)})
    saved_database = Application.get_env(:crew, :database)

    on_exit(fn ->
      for {k, v} <- saved_env, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      Application.put_env(:crew, :database, saved_database)
    end)

    System.delete_env("CREW_DB")
    System.delete_env("CREW_ENCRYPTION_KEYS_RETIRED")
    System.put_env(@env)
    :ok
  end

  defp read_config, do: Config.Reader.read!(@runtime, env: :prod, target: :host)[:crew]

  defp read_repo_config, do: read_config()[Crew.Repo]

  defp config(env) do
    Application.put_env(:crew, :database, "postgres")
    System.delete_env("CREW_WEBHOOKS")
    System.put_env(env)
    read_config()
  end

  test "a release built for Postgres uses DATABASE_URL without CREW_DB set at runtime" do
    Application.put_env(:crew, :database, "postgres")

    repo = read_repo_config()
    assert repo[:url] == @env["DATABASE_URL"]
    refute repo[:database]
  end

  test "a release built for SQLite uses DATABASE_PATH" do
    Application.put_env(:crew, :database, "sqlite")
    System.delete_env("DATABASE_URL")

    repo = read_repo_config()
    assert repo[:database] == "/var/lib/crew/crew.db"
    refute repo[:url]
  end

  # The SQLite image given a team's settings would come up on an empty
  # database, and its tailnet sweep would delete every environment's device.
  test "a release built for SQLite refuses a DATABASE_URL" do
    Application.put_env(:crew, :database, "sqlite")

    assert_raise RuntimeError, ~r/built for SQLite; use the -pg image/, fn ->
      read_repo_config()
    end

    System.put_env("DATABASE_URL", "")
    assert read_repo_config()[:database] == "/var/lib/crew/crew.db"
  end

  test "CREW_DB at runtime that disagrees with the build is refused" do
    Application.put_env(:crew, :database, "sqlite")
    System.put_env("CREW_DB", "postgres")

    assert_raise RuntimeError, ~r/built for sqlite/, fn -> read_repo_config() end
  end

  test "an empty CREW_DB counts as unset" do
    Application.put_env(:crew, :database, "postgres")
    System.put_env("CREW_DB", "")

    assert read_repo_config()[:url] == @env["DATABASE_URL"]
  end

  test "CREW_WEBHOOKS=off is poll-only mode" do
    assert Keyword.fetch!(config(%{"CREW_WEBHOOKS" => "off"}), :webhooks) == false
    assert Keyword.fetch!(config(%{}), :webhooks) == true
  end

  test "a CREW_WEBHOOKS that isn't on or off is refused" do
    assert_raise RuntimeError, ~r/CREW_WEBHOOKS/, fn -> config(%{"CREW_WEBHOOKS" => "maybe"}) end
  end

  test "the scheduling knobs have the spec's defaults" do
    c = config(%{})
    assert c[:idle_grace_s] == 30
    assert c[:idle_max_s] == 600
    assert c[:job_max_s] == 22_500
    assert c[:hook_port] == 4001
    assert c[:log_limit_bytes] == 104_857_600
  end

  defp vault_keys do
    Application.put_env(:crew, :database, "postgres")
    {Crew.Vault.Cipher, opts} = read_config()[Crew.Vault][:ciphers][:default]
    opts[:keys]
  end

  test "CREW_ENCRYPTION_KEY is the key everything is encrypted with" do
    assert vault_keys() == [Base.decode64!(@env["CREW_ENCRYPTION_KEY"])]
  end

  # It would boot, and the first encryption (saving the GitHub App at
  # the end of setup, after the manifest code is spent) would fail.
  test "a CREW_ENCRYPTION_KEY that isn't 32 bytes is refused" do
    for key <- [
          # SECRET_KEY_BASE's recipe, and `openssl rand -hex 32`
          Base.encode64(:crypto.strong_rand_bytes(48)),
          Base.encode16(:crypto.strong_rand_bytes(32)),
          Base.encode64(:crypto.strong_rand_bytes(16))
        ] do
      System.put_env("CREW_ENCRYPTION_KEY", key)

      assert_raise RuntimeError, ~r/CREW_ENCRYPTION_KEY is \d+ bytes, not 32/, fn ->
        vault_keys()
      end
    end
  end

  test "a CREW_ENCRYPTION_KEY that isn't base64 is refused" do
    System.put_env("CREW_ENCRYPTION_KEY", "not base64!")

    assert_raise RuntimeError, ~r/CREW_ENCRYPTION_KEY isn't base64/, fn -> vault_keys() end
  end

  test "a trailing newline on CREW_ENCRYPTION_KEY is ignored" do
    System.put_env("CREW_ENCRYPTION_KEY", @env["CREW_ENCRYPTION_KEY"] <> "\n")

    assert vault_keys() == [Base.decode64!(@env["CREW_ENCRYPTION_KEY"])]
  end

  test "CREW_ENCRYPTION_KEYS_RETIRED are kept for reading, after the current key" do
    old = for _ <- 1..2, do: :crypto.strong_rand_bytes(32)
    System.put_env("CREW_ENCRYPTION_KEYS_RETIRED", Enum.map_join(old, ", ", &Base.encode64/1))

    assert vault_keys() == [Base.decode64!(@env["CREW_ENCRYPTION_KEY"]) | old]
  end

  test "a retired key that isn't 32 bytes is refused" do
    System.put_env("CREW_ENCRYPTION_KEYS_RETIRED", Base.encode64("short"))

    assert_raise RuntimeError, ~r/CREW_ENCRYPTION_KEYS_RETIRED/, fn -> vault_keys() end
  end

  # A development Flatcar VM reaches the Mac's control plane on the
  # vmnet bridge (192.168.64.1), not loopback.
  describe "development" do
    setup do
      saved = System.get_env("CREW_LISTEN_IP")

      on_exit(fn ->
        if saved,
          do: System.put_env("CREW_LISTEN_IP", saved),
          else: System.delete_env("CREW_LISTEN_IP")
      end)

      System.delete_env("CREW_LISTEN_IP")
    end

    defp dev_http do
      Config.Reader.read!(@runtime, env: :dev, target: :host)[:crew][CrewWeb.Endpoint][:http]
    end

    test "listens where CREW_LISTEN_IP says" do
      System.put_env("CREW_LISTEN_IP", "0.0.0.0")
      assert dev_http()[:ip] == {0, 0, 0, 0}
    end

    test "otherwise leaves dev.exs's loopback alone" do
      refute Keyword.has_key?(dev_http(), :ip)
    end

    test "refuses a CREW_LISTEN_IP that isn't an address" do
      System.put_env("CREW_LISTEN_IP", "everywhere")
      assert_raise RuntimeError, ~r/CREW_LISTEN_IP/, fn -> dev_http() end
    end
  end
end
