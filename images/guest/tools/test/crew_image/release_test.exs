defmodule CrewImage.ReleaseTest do
  @moduledoc "Signing a release's agent and cache tarballs (spec §20.1 item 6)."
  use ExUnit.Case, async: true

  alias CrewImage.Release

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
end
