defmodule CrewWeb.SizesLiveTest do
  @moduledoc "Sizes & labels (§17.3): sizes, aliases, and the label tester."
  use CrewWeb.ConnCase

  alias Crew.{Repo, Sizes}

  setup %{conn: conn} do
    box_fixture(
      name: "m4",
      capabilities: capabilities(vcpus: 18, memory_mib: 110_592, max_vcpus_per_vm: 18)
    )

    %{conn: log_in(conn, user_fixture(role: "admin"))}
  end

  test "lists the sizes with the default marked", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/sizes")
    assert has_element?(view, "#sizes", "xs")
    assert has_element?(view, "#size-m", "default")
  end

  test "adds a size, audited", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/sizes")

    view
    |> form("#new-size", size: %{name: "gpu", vcpus: "6", memory_mib: "24576", disk_gib: "80"})
    |> render_submit()

    assert has_element?(view, "#sizes", "gpu")
    assert Repo.get_by(Crew.Sizes.Size, name: "gpu")
  end

  test "makes another size the default, and retires one", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/sizes")
    l = Repo.get_by!(Crew.Sizes.Size, name: "l")
    view |> element("#size-l button", "Make default") |> render_click()
    assert Sizes.default().id == l.id
    view |> element("#size-xs button", "Retire") |> render_click()
    assert Repo.get_by!(Crew.Sizes.Size, name: "xs").retired_at
  end

  test "adds and removes an alias", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/sizes")
    m = Repo.get_by!(Crew.Sizes.Size, name: "m")

    view
    |> form("#new-alias",
      label_alias: %{labels: "self-hosted, linux", size_id: m.id, arch: "any"}
    )
    |> render_submit()

    assert has_element?(view, "#aliases", "linux, self-hosted")
    [a] = Sizes.list_aliases()
    view |> element("#alias-#{a.id} button", "Remove") |> render_click()
    refute has_element?(view, "#alias-#{a.id}")
  end

  test "a size named before the -spare rule says to rename it", %{conn: conn} do
    for name <- ["spare", "big-spare"] do
      Repo.insert!(%Crew.Sizes.Size{name: name, vcpus: 2, memory_mib: 4096, disk_gib: 40})
    end

    {:ok, view, _} = live(conn, ~p"/admin/sizes")

    assert has_element?(
             view,
             "#size-spare-warning",
             "can't be spare: rename it to use crew-spare"
           )

    assert has_element?(view, "#size-card-spare", "rename it to use crew-spare")

    assert has_element?(
             view,
             "#size-big-spare-warning",
             "can't end in -spare: rename it to use crew-big-spare"
           )

    assert has_element?(view, "#size-big-spare-warning", "finish their jobs first")
    refute has_element?(view, "#size-m-warning")
  end

  describe "the label tester" do
    test "a Crew label: its size, arch and the boxes that could hold it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/sizes")

      view
      |> form("#label-tester", %{"runs_on" => "[self-hosted, crew-l-arm64]"})
      |> render_change()

      assert has_element?(view, "#tested", "Crew job")
      assert has_element?(view, "#tested", "l")
      assert has_element?(view, "#tested", "arm64")
      assert has_element?(view, "#tested", "m4")
      assert has_element?(view, "#tested", "crew-l-arm64, self-hosted")
    end

    test "a spare label: spare, and the boxes whose spare share could hold it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/sizes")

      view |> form("#label-tester", %{"runs_on" => "crew-l-spare"}) |> render_change()
      assert has_element?(view, "#tested", "spare")
      assert has_element?(view, "#tested", "spare share could hold it: m4")

      # m4 offers 25.5 vCPUs, so half of it can't hold 16, though all of it can.
      view |> form("#label-tester", %{"runs_on" => "crew-xl-spare"}) |> render_change()
      assert has_element?(view, "#tested", "No box's spare share could hold it")

      view |> form("#label-tester", %{"runs_on" => "crew-xl"}) |> render_change()
      refute has_element?(view, "#tested", "spare")
      assert has_element?(view, "#tested", "Boxes that could hold it: m4")
    end

    test "not Crew's, and unsatisfiable", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/sizes")
      view |> form("#label-tester", %{"runs_on" => "ubuntu-latest"}) |> render_change()
      assert has_element?(view, "#tested", "Not a Crew job")
      view |> form("#label-tester", %{"runs_on" => "crew-huge"}) |> render_change()
      assert has_element?(view, "#tested", "unknown size huge")
      view |> form("#label-tester", %{"runs_on" => "crew-xl-x64"}) |> render_change()
      assert has_element?(view, "#tested", "No box could hold it")
    end
  end

  test "members can't open it" do
    conn = get(log_in(build_conn(), user_fixture()), ~p"/admin/sizes")
    assert conn.status == 404
  end

  test "the admin sidebar links to it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[href="/admin/sizes"]), "Sizes")
  end
end
