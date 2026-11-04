defmodule CrewWeb.CachesLiveTest do
  @moduledoc "The Caches page (§17.3): per box stats, hosts, the allowlist with its public check, purge, rotate CA."
  use CrewWeb.ConnCase, async: false

  import Ecto.Query

  alias Crew.{Caches, Repo}

  setup %{conn: conn} do
    box = box_fixture(name: "m4")
    {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})
    %{conn: log_in(conn, user_fixture(role: "admin")), box: box}
  end

  defp stats(box) do
    {:ok, e} =
      CrewProtocol.Event.new("cache.stats", %{
        "t" => System.os_time(:millisecond),
        "hosts" => [
          %{"host" => "ghcr.io", "hits" => 9, "misses" => 1, "bytes_served" => 3_000_000_000}
        ],
        "top" => [
          %{
            "host" => "ghcr.io",
            "repo" => "actions/runner",
            "hits" => 9,
            "bytes_served" => 3_000_000_000
          }
        ]
      })

    Crew.Agents.handle_event(box.id, e)
  end

  test "each box's hit rate, bytes and top images", %{conn: conn, box: box} do
    stats(box)
    {:ok, view, _} = live(conn, ~p"/admin/caches")
    assert has_element?(view, "#cache-#{box.id}", "m4")
    assert has_element?(view, "#cache-#{box.id}", "90%")
    assert has_element?(view, "#cache-#{box.id}", "2.8 GiB")
    assert has_element?(view, "#cache-#{box.id}", "ghcr.io/actions/runner")
  end

  test "enabling hosts and rotating the CA", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/caches")
    hosts = Map.new(CrewProtocol.Hosts.names(), &{&1, to_string(&1 in ["ghcr.io", "quay.io"])})
    view |> form("#hosts", hosts: hosts) |> render_submit()
    assert Caches.config().enabled_hosts == ["ghcr.io", "quay.io"]
    assert_receive {:dispatch, %{type: "cache.config"}}

    gen = Caches.config().ca_generation
    view |> element("#rotate-ca") |> render_click()
    assert Caches.config().ca_generation == gen + 1
  end

  test "an allowlist entry needs a public example; removing one", %{conn: conn} do
    Req.Test.stub(Crew.Caches, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)
    {:ok, view, _} = live(conn, ~p"/admin/caches")

    view
    |> form("#new-entry", entry: %{entry: "quay.io/mona/*", example: "quay.io/mona/app:1"})
    |> render_submit()

    assert render(view) =~ "anyone can pull without a login"
    refute "quay.io/mona/*" in Caches.config().allowlist

    view |> element(~s([data-entry="ghcr.io/actions/*"] button)) |> render_click()
    refute "ghcr.io/actions/*" in Caches.config().allowlist
    assert Repo.exists?(from e in Crew.Audit.Event, where: e.action == "cache.allowlist_remove")
  end

  test "purging a box's cache", %{conn: conn, box: box} do
    {:ok, view, _} = live(conn, ~p"/admin/caches")
    view |> element("#purge-#{box.id}") |> render_click()
    assert_receive {:dispatch, %{type: "cache.purge", payload: %{scope: "all"}}}
  end

  test "members can't see it" do
    assert get(log_in(build_conn(), user_fixture()), ~p"/admin/caches").status == 404
  end
end
