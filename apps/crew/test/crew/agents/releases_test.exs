defmodule Crew.Agents.ReleasesTest do
  @moduledoc """
  The agent-release registry (§20.1, §20.2): the signed agent and cache
  tarballs the control plane's image carries, registered from
  CREW_AGENT_RELEASE_DIR at boot, and the URLs a Flatcar box's first
  install downloads them from.
  """
  use Crew.DataCase

  import Crew.AgentReleaseFixtures

  alias Crew.Agents.{Release, Releases}
  alias Crew.ImageFixtures

  setup do
    key = ImageFixtures.keypair()
    ImageFixtures.trust(key)
    %{key: key, dir: tmp_dir("agent-releases")}
  end

  test "registers the bundle's signed agent and cache tarballs", %{key: key, dir: dir} do
    files = write_release(dir, key, "0.3.0", "linux-amd64")
    write_release(dir, key, "0.3.0", "darwin-arm64", components: ["agent"])

    assert %{registered: 3, failed: []} = Releases.register_bundle(dir)

    agent = Releases.get("agent", "0.3.0", "linux-amd64")
    assert %Release{sha256: sha, signature: sig, path: path, size: size} = agent
    assert sha == files["agent"].sha256
    assert sig == files["agent"].signature
    assert path == files["agent"].path
    assert size == byte_size(files["agent"].bytes)

    assert %Release{} = Releases.get("cache", "0.3.0", "linux-amd64")
    assert %Release{} = Releases.get("agent", "0.3.0", "darwin-arm64")
    assert Releases.get("cache", "0.3.0", "darwin-arm64") == nil
  end

  test "registering the same bundle again changes nothing", %{key: key, dir: dir} do
    write_release(dir, key, "0.3.0", "linux-amd64")
    Releases.register_bundle(dir)
    assert %{registered: 2, failed: []} = Releases.register_bundle(dir)
    assert length(Releases.list()) == 2
  end

  test "refuses a tarball that doesn't match its .sha256", %{key: key, dir: dir} do
    files = write_release(dir, key, "0.3.0", "linux-amd64")
    File.write!(files["agent"].path <> ".sha256", String.duplicate("0", 64) <> "\n")

    assert %{registered: 1, failed: [{"crew-agent-0.3.0-linux-amd64.tar.gz", reason}]} =
             Releases.register_bundle(dir)

    assert reason =~ "SHA-256"
    assert Releases.get("agent", "0.3.0", "linux-amd64") == nil
  end

  test "refuses a signature the release key didn't make", %{key: key, dir: dir} do
    write_release(dir, ImageFixtures.keypair(), "0.3.0", "linux-amd64", components: ["agent"])
    write_release(dir, key, "0.3.0", "linux-amd64", components: ["cache"])

    assert %{registered: 1, failed: [{_, reason}]} = Releases.register_bundle(dir)
    assert reason =~ "signature"
  end

  test "a signature for another target or version doesn't stand in", %{key: key, dir: dir} do
    files = write_release(dir, key, "0.3.0", "linux-amd64", components: ["agent"])

    other =
      CrewProtocol.Auth.sign_release("0.3.0", "linux-arm64", files["agent"].sha256, key.private)

    File.write!(files["agent"].path <> ".sig", other)

    assert %{registered: 0, failed: [_]} = Releases.register_bundle(dir)
  end

  test "refuses everything without a release key", %{key: key, dir: dir} do
    write_release(dir, key, "0.3.0", "linux-amd64")
    Application.put_env(:crew, :release_public_key, nil)

    assert %{registered: 0, failed: [{_, reason}, _]} = Releases.register_bundle(dir)
    assert reason =~ "CREW_RELEASE_PUBLIC_KEY"
  end

  test "a tarball without its .sig or .sha256 isn't registered", %{key: key, dir: dir} do
    files = write_release(dir, key, "0.3.0", "linux-amd64")
    File.rm!(files["agent"].path <> ".sig")
    File.rm!(files["cache"].path <> ".sha256")

    assert %{registered: 0, failed: failed} = Releases.register_bundle(dir)
    assert length(failed) == 2
  end

  test "files that aren't release tarballs are left alone", %{dir: dir} do
    File.write!(Path.join(dir, "README"), "hi")
    File.write!(Path.join(dir, "crew-agent-latest-linux-amd64.tar.gz"), "x")
    File.write!(Path.join(dir, "crew-guest-0.3.0-arm64.manifest.json"), "{}")

    assert %{registered: 0, failed: []} = Releases.register_bundle(dir)
  end

  test "an unreadable or missing directory registers nothing" do
    assert %{registered: 0, failed: []} = Releases.register_bundle("/nonexistent/crew")
  end

  describe "what a new box installs" do
    test "the newest version with both tarballs for the target", %{key: key, dir: dir} do
      write_release(dir, key, "0.2.0", "linux-amd64")
      write_release(dir, key, "0.10.0", "linux-amd64")
      # No cache: not an install set.
      write_release(dir, key, "0.11.0", "linux-amd64", components: ["agent"])
      write_release(dir, key, "0.12.0-rc.1", "linux-amd64")
      Releases.register_bundle(dir)

      assert {:ok, %{version: "0.10.0", agent: agent, cache: cache}} =
               Releases.install_set("linux-amd64")

      assert agent.component == "agent"
      assert cache.component == "cache"
      assert {:error, :no_release} = Releases.install_set("linux-arm64")
    end

    test "a prerelease when there's nothing else", %{key: key, dir: dir} do
      write_release(dir, key, "0.12.0-rc.1", "linux-arm64")
      Releases.register_bundle(dir)
      assert {:ok, %{version: "0.12.0-rc.1"}} = Releases.install_set("linux-arm64")
    end

    test "a release whose files have gone doesn't count", %{key: key, dir: dir} do
      write_release(dir, key, "0.3.0", "linux-amd64")
      files = write_release(dir, key, "0.4.0", "linux-amd64")
      Releases.register_bundle(dir)
      File.rm!(files["cache"].path)

      assert {:ok, %{version: "0.3.0"}} = Releases.install_set("linux-amd64")
    end
  end

  describe "download URLs" do
    setup %{key: key, dir: dir} do
      write_release(dir, key, "0.3.0", "linux-amd64")
      Releases.register_bundle(dir)
      prev = Application.get_env(:crew, :dev)
      on_exit(fn -> Application.put_env(:crew, :dev, prev) end)
      %{release: Releases.get("agent", "0.3.0", "linux-amd64")}
    end

    # §20.2: a first install downloads from the GitHub release, never from
    # the control plane.
    test "are the GitHub release's", %{release: release} do
      Application.put_env(:crew, :dev, false)

      assert Releases.url(release) ==
               "https://github.com/ntodd/crew/releases/download/v0.3.0/crew-agent-0.3.0-linux-amd64.tar.gz"
    end

    test "are the control plane's own in development", %{release: release} do
      Application.put_env(:crew, :dev, true)

      assert Releases.url(release) ==
               Crew.Config.base_url() <>
                 "/agent/releases/0.3.0/linux-amd64/crew-agent-0.3.0-linux-amd64.tar.gz"
    end

    test "in development, the GitHub release's when the file isn't here", %{release: release} do
      Application.put_env(:crew, :dev, true)
      File.rm!(release.path)
      assert Releases.url(release) =~ "/releases/download/v0.3.0/"
    end
  end

  test "names a release's file as CI does" do
    assert Releases.file_name("cache", "1.2.3", "linux-arm64") ==
             "crew-cache-1.2.3-linux-arm64.tar.gz"
  end
end
