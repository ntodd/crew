defmodule CrewImage.ReleaseTest do
  @moduledoc "Signing a release's agent and cache tarballs (spec §20.1 item 6)."
  use ExUnit.Case, async: true

  alias CrewImage.{Keys, Release}
  alias Mix.Tasks.Crew.Verify

  setup do
    dir = Path.join(System.tmp_dir!(), "crew-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {public, private} = CrewProtocol.Auth.generate_keypair()
    %{dir: dir, public: public, private: private}
  end

  test "each tarball gets its SHA-256 and a signature over version, target and SHA-256", ctx do
    for name <- ~w(crew-agent-0.2.0-linux-arm64.tar.gz crew-cache-0.2.0-linux-arm64.tar.gz) do
      File.write!(Path.join(ctx.dir, name), "tarball " <> name)
    end

    File.write!(Path.join(ctx.dir, "notes.txt"), "not a tarball")

    assert {:ok, signed} = Release.sign_dir(ctx.dir, ctx.private)
    assert length(signed) == 2

    path = Path.join(ctx.dir, "crew-agent-0.2.0-linux-arm64.tar.gz")
    sha = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    assert File.read!(path <> ".sha256") == "#{sha}  crew-agent-0.2.0-linux-arm64.tar.gz\n"
    sig = File.read!(path <> ".sig")
    assert :ok = CrewProtocol.Auth.verify_release("0.2.0", "linux-arm64", sha, sig, ctx.public)
    refute File.exists?(Path.join(ctx.dir, "notes.txt.sig"))
  end

  test "a name that isn't crew-<agent|cache>-<version>-<target>.tar.gz is refused", ctx do
    File.write!(Path.join(ctx.dir, "crew-agent-0.2.0-plan9-mips.tar.gz"), "x")

    assert {:error, {:bad_name, "crew-agent-0.2.0-plan9-mips.tar.gz"}} =
             Release.sign_dir(ctx.dir, ctx.private)
  end

  describe "verify_dir/3: what the control plane and a box will check" do
    setup ctx do
      for name <- ~w(crew-agent-0.2.0-linux-arm64.tar.gz crew-cache-0.2.0-linux-arm64.tar.gz) do
        File.write!(Path.join(ctx.dir, name), "tarball " <> name)
      end

      {:ok, _} = Release.sign_dir(ctx.dir, ctx.private)
      :ok
    end

    test "every tarball matches its .sha256 and its signature verifies", ctx do
      assert {:ok, ["crew-agent-0.2.0-linux-arm64.tar.gz", "crew-cache-0.2.0-linux-arm64.tar.gz"]} =
               Release.verify_dir(ctx.dir, ctx.public)
    end

    test "a tarball changed after signing", ctx do
      File.write!(Path.join(ctx.dir, "crew-agent-0.2.0-linux-arm64.tar.gz"), "something else")

      assert {:error, [{"crew-agent-0.2.0-linux-arm64.tar.gz", :sha256_mismatch}]} =
               Release.verify_dir(ctx.dir, ctx.public)
    end

    test "a .sha256 changed to match, which the signature still catches", ctx do
      path = Path.join(ctx.dir, "crew-agent-0.2.0-linux-arm64.tar.gz")
      File.write!(path, "something else")
      sha = :crypto.hash(:sha256, "something else") |> Base.encode16(case: :lower)
      File.write!(path <> ".sha256", "#{sha}  #{Path.basename(path)}\n")

      assert {:error, [{"crew-agent-0.2.0-linux-arm64.tar.gz", :bad_signature}]} =
               Release.verify_dir(ctx.dir, ctx.public)
    end

    test "another key", ctx do
      {other, _} = CrewProtocol.Auth.generate_keypair()
      assert {:error, problems} = Release.verify_dir(ctx.dir, other)
      assert Enum.all?(problems, &match?({_, :bad_signature}, &1))
      assert length(problems) == 2
    end

    test "a tarball without its signature", ctx do
      File.rm!(Path.join(ctx.dir, "crew-cache-0.2.0-linux-arm64.tar.gz.sig"))

      assert {:error, [{"crew-cache-0.2.0-linux-arm64.tar.gz", :no_signature}]} =
               Release.verify_dir(ctx.dir, ctx.public)
    end

    test "nothing to verify is a failure, not a pass", ctx do
      empty = Path.join(ctx.dir, "empty")
      File.mkdir_p!(empty)
      assert {:error, :no_tarballs} = Release.verify_dir(empty, ctx.public)
    end
  end

  describe "mix crew.verify" do
    setup ctx do
      File.write!(Path.join(ctx.dir, "crew-agent-0.2.0-linux-amd64.tar.gz"), "tarball")
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    test "passes a release signed with the given key", ctx do
      {:ok, _} = Release.sign_dir(ctx.dir, ctx.private)

      Verify.run([ctx.dir, "--public-key", Base.encode64(ctx.public)])
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "crew-agent-0.2.0-linux-amd64.tar.gz"
    end

    test "fails one that isn't", ctx do
      {:ok, _} = Release.sign_dir(ctx.dir, ctx.private)
      {other, _} = CrewProtocol.Auth.generate_keypair()

      assert_raise Mix.Error, ~r/bad_signature/, fn ->
        Verify.run([ctx.dir, "--public-key", Base.encode64(other)])
      end
    end

    test "--release refuses the test key", ctx do
      {:ok, test_private} = Keys.load_private(file: Keys.test_key_path())
      {:ok, _} = Release.sign_dir(ctx.dir, test_private)

      assert_raise Mix.Error, ~r/test key/, fn ->
        Verify.run([
          ctx.dir,
          "--release",
          "--public-key-file",
          Path.expand("../../../keys/test-signing.pub", __DIR__)
        ])
      end
    end
  end
end
