defmodule CrewWeb.ImagesLiveTest do
  @moduledoc "The Images page (§17.3): defaults, versions, freshness, rollout per box, pin and unpin."
  use CrewWeb.ConnCase, async: false

  import Ecto.Query

  alias Crew.Images
  alias Crew.Images.Image
  alias Crew.Repo

  defp image(version, attrs \\ []) do
    Repo.insert!(
      struct(
        %Image{
          version: version,
          arch: "arm64",
          manifest: version,
          manifest_sha256: version,
          signature: "s",
          kernel_sha256: String.duplicate("a", 64),
          kernel_size: 1,
          rootfs_sha256: String.duplicate("b", 64),
          rootfs_size: 1,
          runner_version: "2.338.2",
          docker_version: "29.9.2",
          kernel_version: "6.18.60-crew",
          mirror_state: "ready",
          registered_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  setup %{conn: conn} do
    old = image("1.0.0", registered_at: DateTime.add(DateTime.utc_now(), -86_400))
    new = image("1.1.0")
    box = box_fixture(name: "m4")
    Images.put_box_state(box.id, old.id, "ready")
    Images.put_box_state(box.id, new.id, "downloading", %{progress: 40})

    %{conn: log_in(conn, user_fixture(role: "admin")), old: old, new: new, box: box}
  end

  test "each arch's default, its versions, and its rollout on each box", %{conn: conn, new: new} do
    {:ok, view, _} = live(conn, ~p"/admin/images")

    assert has_element?(view, "#default-arm64", "1.1.0")
    assert has_element?(view, "#default-arm64", "2.338.2")
    assert has_element?(view, "#default-arm64", "29.9.2")
    assert has_element?(view, "#image-#{new.id}", "default")
    assert has_element?(view, "#rollout-arm64", "m4")
    assert has_element?(view, "#rollout-arm64", "40%")
  end

  test "pinning the previous image rolls back, audited; unpinning follows the newest again",
       %{conn: conn, old: old} do
    {:ok, view, _} = live(conn, ~p"/admin/images")

    view |> element("#pin-#{old.id}") |> render_click()
    assert Repo.reload!(old).pinned
    assert Images.defaults()["arm64"].default == old.id
    assert has_element?(view, "#default-arm64", "1.0.0")
    assert has_element?(view, "#default-arm64", "pinned")

    view |> element("#unpin-#{old.id}") |> render_click()
    refute Repo.reload!(old).pinned
    assert Repo.exists?(from e in Crew.Audit.Event, where: e.action == "image.pin")
    assert Repo.exists?(from e in Crew.Audit.Event, where: e.action == "image.unpin")
  end

  test "a runner falling behind is flagged", %{conn: conn} do
    published = DateTime.utc_now() |> DateTime.add(-22 * 86_400) |> DateTime.to_iso8601()
    Crew.Settings.put("runner_releases", [%{"version" => "2.339.0", "published_at" => published}])

    {:ok, view, _} = live(conn, ~p"/admin/images")
    assert has_element?(view, "#runner-freshness", "22 days")
  end

  test "an image whose files couldn't be fetched says why, and can be tried again", %{conn: conn} do
    failed =
      image("1.2.0", mirror_state: "failed", mirror_error: "downloading the rootfs got HTTP 404")

    {:ok, view, _} = live(conn, ~p"/admin/images")
    assert has_element?(view, "#image-#{failed.id}", "HTTP 404")
    view |> element("#fetch-#{failed.id}") |> render_click()
    assert Repo.reload!(failed).mirror_state == "pending"
  end

  test "members can't see it" do
    assert get(log_in(build_conn(), user_fixture()), ~p"/admin/images").status == 404
  end

  test "pinning an image whose files were let go fetches them first", %{conn: conn} do
    old =
      image("0.9.0",
        mirror_state: "evicted",
        registered_at: DateTime.add(DateTime.utc_now(), -9 * 86_400)
      )

    {:ok, view, _} = live(conn, ~p"/admin/images")
    assert has_element?(view, "#image-#{old.id}", "files let go")
    refute has_element?(view, "#fetch-#{old.id}")

    view |> element("#pin-#{old.id}") |> render_click()
    old = Repo.reload!(old)
    assert old.pinned and old.mirror_state == "pending"
    assert has_element?(view, "#image-#{old.id}", "fetching")
  end
end
