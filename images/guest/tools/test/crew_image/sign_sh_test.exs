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

  describe "release tarballs (§20.1 item 6)" do
    @tarballs ~w(crew-agent-0.2.0-linux-amd64.tar.gz crew-cache-0.2.0-linux-arm64.tar.gz
                 crew-agent-0.2.0-rc.1-darwin-arm64.tar.gz)

    defp tarballs!(dir) do
      File.mkdir_p!(dir)
      for name <- @tarballs, do: File.write!(Path.join(dir, name), "tarball bytes of " <> name)
      dir
    end

    test "writes the same .sha256 and .sig as mix crew.sign", %{tmp_dir: tmp} do
      {public, private} = Auth.generate_keypair()
      elixir = tarballs!(Path.join(tmp, "elixir"))
      openssl = tarballs!(Path.join(tmp, "openssl"))

      assert {:ok, _} = CrewImage.Release.sign_dir(elixir, private)

      files = for name <- @tarballs, do: Path.join(openssl, name)
      key = [{"CREW_RELEASE_SIGNING_KEY", Base.encode64(private)}]
      assert {_, 0} = sign_sh(files, key)

      for name <- @tarballs, ext <- [".sha256", ".sig"] do
        assert File.read!(Path.join(openssl, name <> ext)) ==
                 File.read!(Path.join(elixir, name <> ext)),
               "#{name}#{ext} differs"
      end

      path = Path.join(openssl, "crew-agent-0.2.0-rc.1-darwin-arm64.tar.gz")
      sha = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

      assert :ok =
               Auth.verify_release(
                 "0.2.0-rc.1",
                 "darwin-arm64",
                 sha,
                 File.read!(path <> ".sig"),
                 public
               )
    end

    test "signs manifests and tarballs in one run", %{tmp_dir: tmp, paths: paths} do
      {public, private} = Auth.generate_keypair()
      [tarball | _] = for name <- @tarballs, do: Path.join(tarballs!(Path.join(tmp, "t")), name)

      assert {_, 0} =
               sign_sh([paths.manifest, tarball], [
                 {"CREW_RELEASE_SIGNING_KEY", Base.encode64(private)}
               ])

      assert Artifacts.verify(paths.manifest, public) == :ok
      assert File.exists?(tarball <> ".sig")
    end

    test "refuses a name that isn't crew-<agent|cache>-<version>-<target>.tar.gz",
         %{tmp_dir: tmp} do
      key = [{"CREW_RELEASE_SIGNING_KEY", Base.encode64(elem(Auth.generate_keypair(), 1))}]

      for name <- ~w(crew-agent-0.2.0-plan9-mips.tar.gz crew-guest-0.2.0-linux-amd64.tar.gz
                     crew-agent-latest-linux-amd64.tar.gz notes.txt) do
        path = Path.join(tmp, name)
        File.write!(path, "x")
        assert {out, status} = sign_sh([path], key)
        assert status != 0, "#{name} was signed"
        assert out =~ name
        refute File.exists?(path <> ".sig")
      end
    end

    test "refuses the test key with --release", %{tmp_dir: tmp} do
      [tarball | _] = for name <- @tarballs, do: Path.join(tarballs!(tmp), name)

      assert {out, status} =
               sign_sh(["--release", "--key-file", Keys.test_key_path(), tarball], [])

      assert status != 0
      assert out =~ "test key"
      refute File.exists?(tarball <> ".sig")
    end
  end
end
