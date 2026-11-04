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

  test "the box page lists its VMs and what they hold, live", %{conn: conn} do
    box = box_fixture(name: "m4pro")
    repo = repo_fixture(name: "web")
    size = Crew.Repo.get_by!(Crew.Sizes.Size, name: "m")
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    assert has_element?(view, "#vms", "No VMs")
    assert has_element?(view, "#allocation", "0 of")

    [vm] =
      Crew.VMs.create_placements([
        %{class: {repo.id, ["crew-m"]}, box: box, size: size, image_id: nil}
      ])

    Phoenix.PubSub.broadcast(Crew.PubSub, "box:#{box.id}", {:box_changed, box.id})

    assert render(view) =~ vm.name
    assert has_element?(view, "#vm-#{vm.id}", "requested")
    assert has_element?(view, "#vm-#{vm.id}", "acme/web")
    assert has_element?(view, "#allocation", "4 of")
    Crew.VMCase.stop_vm_servers()
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

    test "a dedicated Linux machine asks for its data disk, then offers the Ignition", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/boxes/new")
      refute has_element?(view, "#box_data_disk")

      view |> form("#add-box", %{"box" => %{"box_type" => "linux-metal"}}) |> render_change()
      assert has_element?(view, "#box_data_disk")

      html =
        view
        |> form("#add-box", %{"box" => %{"box_name" => "rack1", "box_type" => "linux-metal"}})
        |> render_submit()

      assert html =~ "is needed for a dedicated Linux machine"

      html =
        view
        |> form("#add-box", %{
          "box" => %{
            "box_name" => "rack1",
            "box_type" => "linux-metal",
            "data_disk" => "/dev/nvme1n1"
          }
        })
        |> render_submit()

      assert [_, token] = Regex.run(~r/value="(cj_[A-Za-z0-9_-]+)"/, html)

      assert has_element?(
               view,
               "#ignition-download[action='/agent/flatcar/ignition'][method='post']"
             )

      assert has_element?(view, "#ignition-download select[name=arch] option[value=amd64]")
      assert has_element?(view, "#ignition-download select[name=arch] option[value=arm64]")
      assert has_element?(view, "#join-command", "arch=amd64")
      # The file holds the join token and the Tailscale key: made 0600,
      # and deleted once the box has enrolled.
      assert has_element?(view, "#join-command", "(umask 077; curl ")
      assert has_element?(view, "#join-command", "-o crew-rack1.ign)")
      refute render(view) =~ "> crew-rack1.ign"
      assert has_element?(view, "#join-instructions", "Delete it once the box has enrolled")
      assert has_element?(view, "#flatcar-install", "flatcar-install -d")

      assert Crew.Repo.get_by!(Crew.Boxes.JoinToken, box_name: "rack1").data_disk ==
               "/dev/nvme1n1"

      assert String.starts_with?(token, "cj_")
    end

    test "a Flatcar box takes a break-glass SSH key", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes/new")
      refute has_element?(view, "#box_ssh_keys")
      view |> form("#add-box", %{"box" => %{"box_type" => "linux-vm"}}) |> render_change()

      view
      |> form("#add-box", %{
        "box" => %{
          "box_name" => "desk",
          "box_type" => "linux-vm",
          "ssh_keys" => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBreakGlass admin@laptop"
        }
      })
      |> render_submit()

      assert Crew.Repo.get_by!(Crew.Boxes.JoinToken, box_name: "desk").ssh_keys == [
               "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBreakGlass admin@laptop"
             ]
    end

    test "asks for a Tailscale auth key only without an OAuth client", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes/new")
      view |> form("#add-box", %{"box" => %{"box_type" => "mac-vm"}}) |> render_change()
      assert has_element?(view, "#box_tailscale_auth_key")

      Application.put_env(:crew, :tailscale, %{client_id: "k", client_secret: "s", tailnet: "-"})
      on_exit(fn -> Application.delete_env(:crew, :tailscale) end)
      {:ok, view, _} = live(conn, ~p"/boxes/new")
      view |> form("#add-box", %{"box" => %{"box_type" => "mac-vm"}}) |> render_change()
      refute has_element?(view, "#box_tailscale_auth_key")
      assert has_element?(view, "#tailscale-minted")
    end

    test "mac-vz boxes get none of the Flatcar fields", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes/new")
      view |> form("#add-box", %{"box" => %{"box_type" => "mac-vz"}}) |> render_change()
      refute has_element?(view, "#box_ssh_keys")
      refute has_element?(view, "#box_tailscale_auth_key")
      refute has_element?(view, "#box_data_disk")
    end
  end

  describe "reprovisioning a Flatcar box" do
    test "the box page offers the Ignition, with the data disk it was added with", %{
      conn: conn,
      admin: admin
    } do
      scope = Crew.Scope.for_user(admin)

      {:ok, raw} =
        Boxes.create_join_token(scope, %{
          "box_name" => "rack2",
          "box_type" => "linux-metal",
          "data_disk" => "/dev/sdb"
        })

      {public, _} = CrewProtocol.Auth.generate_keypair()
      {:ok, box} = Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})

      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")

      assert has_element?(
               view,
               "#reprovision form[action='/boxes/#{box.id}/reprovision.ign'][method=get]"
             )

      assert has_element?(view, "#reprovision input[name=data_disk][value='/dev/sdb']")
      assert has_element?(view, "#reprovision", "flatcar-install")
    end

    test "a VM box's says to use crew-box reimage", %{conn: conn} do
      box = box_fixture(type: "mac-vm")
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#reprovision", "crew-box reimage")
      refute has_element?(view, "#reprovision input[name=data_disk]")
    end

    test "a mac-vz box has none", %{conn: conn} do
      box = box_fixture(type: "mac-vz")
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      refute has_element?(view, "#reprovision")
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
