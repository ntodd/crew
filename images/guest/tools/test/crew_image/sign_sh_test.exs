defmodule CrewImage.SignShTest do
  @moduledoc """
  images/guest/sign.sh, CI's signer (openssl only), must make exactly the
  signature CrewProtocol.Auth makes: ed25519 is deterministic.
  """
  use ExUnit.Case, async: true

  import CrewImage.TestHelpers

  alias CrewImage.{Artifacts, Keys}
  alias CrewProtocol.Auth

  @sign_sh Path.expand("../../../sign.sh", __DIR__)
  @moduletag :tmp_dir

  defp sign_sh(args, env) do
    System.cmd("bash", [@sign_sh | args], env: env, stderr_to_stdout: true)
  end

  setup %{tmp_dir: dir} do
    files = build_dir!(Path.join(dir, "build"))
    {:ok, paths} = Artifacts.write(Path.join(dir, "release"), manifest_opts(files))
    %{paths: paths}
  end

  test "signs with the key in CREW_RELEASE_SIGNING_KEY, as Auth.sign_manifest does",
       %{paths: paths} do
    {public, private} = Auth.generate_keypair()

    assert {_, 0} =
             sign_sh([paths.manifest], [{"CREW_RELEASE_SIGNING_KEY", Base.encode64(private)}])

    sig = File.read!(paths.signature)
    assert sig == Keys.sign(File.read!(paths.manifest), private)
    assert Artifacts.verify(paths.manifest, public) == :ok
  end

  test "signs with a key file, and refuses the test key with --release", %{paths: paths} do
    assert {_, 0} = sign_sh(["--key-file", Keys.test_key_path(), paths.manifest], [])
    assert Artifacts.verify(paths.manifest, Keys.test_public_key()) == :ok

    File.rm!(paths.signature)

    assert {out, status} =
             sign_sh(["--release", "--key-file", Keys.test_key_path(), paths.manifest], [])

    assert status != 0
    assert out =~ "test key"
    refute File.exists?(paths.signature)
  end

  test "refuses a key that isn't a 32-byte seed", %{paths: paths} do
    assert {out, status} =
             sign_sh([paths.manifest], [{"CREW_RELEASE_SIGNING_KEY", Base.encode64("short")}])

    assert status != 0
    assert out =~ "32"
    refute File.exists?(paths.signature)
  end
end
