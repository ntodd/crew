defmodule CrewWeb.ImageControllerTest do
  @moduledoc "Boxes download an image's files from the control plane (§13.1)."
  use CrewWeb.ConnCase, async: false

  alias Crew.Images.Image
  alias Crew.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "crew-serve-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    kernel = Path.join(dir, "kernel")
    rootfs = Path.join(dir, "rootfs.ext4.zst")
    File.write!(kernel, "kernel-bytes")
    File.write!(rootfs, "0123456789")

    image =
      Repo.insert!(%Image{
        version: "1.0.0",
        arch: "arm64",
        manifest: "{}",
        manifest_sha256: "x",
        signature: "s",
        kernel_sha256: String.duplicate("a", 64),
        kernel_size: 12,
        rootfs_sha256: String.duplicate("b", 64),
        rootfs_size: 10,
        kernel_path: kernel,
        rootfs_path: rootfs,
        mirror_state: "ready",
        registered_at: DateTime.utc_now()
      })

    %{image: image}
  end

  test "the kernel and root filesystem, with their hashes", %{conn: conn, image: image} do
    conn = get(conn, ~p"/images/#{image.id}/kernel")
    assert conn.status == 200
    assert response(conn, 200) == "kernel-bytes"
    assert get_resp_header(conn, "x-crew-sha256") == [image.kernel_sha256]

    conn = get(build_conn(), ~p"/images/#{image.id}/rootfs")
    assert response(conn, 200) == "0123456789"
  end

  test "a download picks up where it stopped", %{conn: conn, image: image} do
    conn = conn |> put_req_header("range", "bytes=4-") |> get(~p"/images/#{image.id}/rootfs")
    assert response(conn, 206) == "456789"
    assert get_resp_header(conn, "content-range") == ["bytes 4-9/10"]

    conn =
      build_conn() |> put_req_header("range", "bytes=20-") |> get(~p"/images/#{image.id}/rootfs")

    assert conn.status == 416
  end

  test "nothing for an image that isn't mirrored, or isn't there", %{conn: conn, image: image} do
    Repo.update!(Ecto.Changeset.change(image, mirror_state: "pending"))
    assert get(conn, ~p"/images/#{image.id}/kernel").status == 404
    assert get(build_conn(), ~p"/images/#{CrewProtocol.uuid7()}/kernel").status == 404
    assert get(build_conn(), ~p"/images/#{image.id}/manifest").status == 404
    assert get(build_conn(), ~p"/images/not-a-uuid/kernel").status == 404
  end
end
