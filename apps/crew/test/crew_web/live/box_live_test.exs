defmodule CrewWeb.BoxLiveTest do
  use CrewWeb.ConnCase

  alias Crew.Boxes

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")
    %{conn: log_in(conn, admin), admin: admin}
  end

  test "the list shows each box with its status, driver and arch", %{conn: conn} do
    box = box_fixture(name: "m1ultra")
    {:ok, view, _} = live(conn, ~p"/boxes")
    assert has_element?(view, "#box-#{box.id}", "m1ultra")
    assert has_element?(view, "#box-#{box.id}", "Offline")
    assert has_element?(view, "#box-#{box.id}", "vz")
    assert has_element?(view, "#box-#{box.id}", "arm64")
  end

  test "an empty fleet says how to start", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/boxes")
    assert has_element?(view, "#boxes-empty", "Add your first box")
  end

  test "the box page shows capabilities, and a box needing approval can be approved", %{
    conn: conn
  } do
    box = box_fixture(name: "m3max")
    {:ok, box} = Boxes.report_capabilities(box, capabilities(vcpus: 64, max_vcpus_per_vm: 64))
    assert box.needs_approval

    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    assert has_element?(view, "#capabilities", "18")
    assert has_element?(view, "#needs-approval", "64")

    view |> element("#approve-capabilities") |> render_click()
    refute has_element?(view, "#needs-approval")
    refute Boxes.get!(box.id).needs_approval
  end

  test "revoking a box", %{conn: conn} do
    box = box_fixture(name: "old")
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    view |> element("#revoke-box") |> render_click()
    assert_redirect(view, ~p"/boxes")
    assert Boxes.get!(box.id).revoked_at
  end

  test "the box page updates live when metrics arrive", %{conn: conn} do
    box = box_fixture()
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")

    Crew.Metrics.record_box(box.id, %{
      t: System.os_time(:millisecond),
      cpu_pct: 42.5,
      mem_used_mib: 1000,
      mem_total_mib: 8000,
      swap_used_mib: 0,
      load1: 1.5,
      disk_used_mib: 10,
      disk_total_mib: 100,
      vm_area_free_mib: 4000,
      cache_used_mib: 0,
      vms_running: 0
    })

    assert render(view) =~ "42.5"
  end

  describe "adding a box" do
    test "makes a join token and shows the mac-vz steps", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes/new")

      html =
        view
        |> form("#add-box", %{"box" => %{"box_name" => "m1ultra", "box_type" => "mac-vz"}})
        |> render_submit()

      assert html =~ "install-macos.sh"
      assert [_, token] = Regex.run(~r/--token (cj_[A-Za-z0-9_-]+)/, html)
      {public, _} = CrewProtocol.Auth.generate_keypair()
      assert {:ok, _} = Boxes.enroll(token, %{"public_key" => Base.encode64(public)})
    end

    test "shows the launcher command for linux-vm and mac-vm", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes/new")

      html =
        view
        |> form("#add-box", %{"box" => %{"box_name" => "m3max", "box_type" => "mac-vm"}})
        |> render_submit()

      assert html =~ "/agent/mac-vm.sh | sudo sh -s -- --token cj_"
    end

    test "names are checked", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes/new")

      html =
        view
        |> form("#add-box", %{"box" => %{"box_name" => "Bad Name", "box_type" => "mac-vz"}})
        |> render_submit()

      assert html =~ "lowercase DNS label"
    end

    test "shows the release key fingerprint to compare", %{conn: conn} do
      {public, _} = CrewProtocol.Auth.generate_keypair()
      Application.put_env(:crew, :release_public_key, Base.encode64(public))
      on_exit(fn -> Application.delete_env(:crew, :release_public_key) end)
      {:ok, view, _} = live(conn, ~p"/boxes/new")

      html =
        view
        |> form("#add-box", %{"box" => %{"box_name" => "x", "box_type" => "mac-vz"}})
        |> render_submit()

      assert html =~ CrewProtocol.Auth.fingerprint(public)
    end
  end

  test "members see boxes but can't add, approve or revoke" do
    member = user_fixture()
    box = box_fixture()
    conn = log_in(build_conn(), member)
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    refute has_element?(view, "#revoke-box")
    assert conn |> get(~p"/boxes/new") |> html_response(404)
  end
end
