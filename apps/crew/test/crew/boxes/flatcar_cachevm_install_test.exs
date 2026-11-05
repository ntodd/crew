defmodule Crew.Boxes.FlatcarCacheVMInstallTest do
  @moduledoc """
  The cache VM's install (crew-cachevm-install, §12.3), run for real:
  the scripts as the Ignition writes them, a directory standing in for
  /srv/crew, and signed fixture tarballs over file:// URLs (as
  flatcar_install_test.exs runs the box's).
  """
  use ExUnit.Case, async: true

  import Crew.AgentReleaseFixtures

  alias Crew.Boxes.Flatcar

  @token "cm_mgmt-token-0123456789abcdef0123456789"

  setup do
    key = Crew.ImageFixtures.keypair()
    root = tmp_dir("cachevm-install")
    files = write_release(Path.join(root, "release"), key, "0.3.0", "linux-arm64")
    %{key: key, root: root, files: files, data: Path.join(root, "srv-crew")}
  end

  defp cache(files, overrides \\ %{}) do
    Map.merge(
      %{
        url: "file://" <> files["cache"].path,
        sha256: files["cache"].sha256,
        signature: files["cache"].signature
      },
      overrides
    )
  end

  defp render_etc(root, key, mode, cache \\ nil) do
    {:ok, config} =
      Flatcar.cachevm_ignition(%{
        mode: mode,
        arch: "arm64",
        ssh_keys: [],
        mgmt_token: if(mode == :provision, do: @token),
        release_key: key.public,
        release: if(mode == :provision, do: %{version: "0.3.0", cache: cache})
      })

    etc = Path.join(root, "etc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(etc)

    for %{"path" => "/etc/crew-box/" <> name, "contents" => %{"source" => "data:;base64," <> b64}} <-
          config["storage"]["files"],
        do: File.write!(Path.join(etc, name), Base.decode64!(b64))

    etc
  end

  defp install(etc, data) do
    System.cmd("sh", [Path.join(etc, "cachevm-install.sh")],
      env: [{"CREW_BOX_ETC", etc}, {"CREW_BOX_DATA", data}],
      stderr_to_stdout: true
    )
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "installs crew_cache and keeps the token on the data disk, root's alone", ctx do
    etc = render_etc(ctx.root, ctx.key, :provision, cache(ctx.files))
    assert {out, 0} = install(etc, ctx.data)
    assert out =~ "crew-box: installed crew_cache 0.3.0"

    release = Path.join(ctx.data, "release")
    assert {:ok, "0.3.0"} = File.read_link(Path.join(release, "current"))
    assert File.read!(Path.join(release, "0.3.0/bin/crew_cache")) =~ "crew_cache 0.3.0"
    assert Bitwise.band(File.stat!(Path.join(release, "0.3.0/bin/crew_cache")).mode, 0o022) == 0

    mgmt = Path.join(ctx.data, "cachevm/mgmt.env")
    assert File.read!(mgmt) == ~s(CREW_CACHE_MGMT_TOKEN="#{@token}"\n)
    assert mode(mgmt) == 0o600
    assert mode(Path.join(ctx.data, "cachevm")) == 0o700
    assert File.dir?(Path.join(ctx.data, "cache"))

    # Nothing left over, and the next boot changes nothing.
    assert release |> File.ls!() |> Enum.sort() == ["0.3.0", "current"]
    assert {out, 0} = install(etc, ctx.data)
    assert out =~ "crew_cache is installed (0.3.0)"
  end

  test "a new OS disk keeps the data disk's cache and token", ctx do
    assert {_, 0} = install(render_etc(ctx.root, ctx.key, :provision, cache(ctx.files)), ctx.data)

    assert {out, 0} = install(render_etc(ctx.root, ctx.key, :reprovision), ctx.data)
    assert out =~ "crew_cache is installed (0.3.0)"
    assert File.read!(Path.join(ctx.data, "cachevm/mgmt.env")) =~ @token
  end

  test "a reprovision onto an empty data disk says what's missing", ctx do
    assert {out, status} = install(render_etc(ctx.root, ctx.key, :reprovision), ctx.data)
    assert status != 0
    assert out =~ "management token isn't on the data disk"
  end

  test "refuses a tarball that doesn't match its digest or isn't signed by the key", ctx do
    bad_sha = cache(ctx.files, %{sha256: String.duplicate("0", 64)})
    assert {out, status} = install(render_etc(ctx.root, ctx.key, :provision, bad_sha), ctx.data)
    assert status != 0
    assert out =~ "doesn't match its SHA-256"
    refute File.exists?(Path.join(ctx.data, "release/current"))

    other = Crew.ImageFixtures.keypair()

    assert {out, status} =
             install(render_etc(ctx.root, other, :provision, cache(ctx.files)), ctx.data)

    assert status != 0
    assert out =~ "doesn't verify against the release key"
    refute File.exists?(Path.join(ctx.data, "release/current"))
  end
end
