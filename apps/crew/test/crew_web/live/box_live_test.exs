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

  describe "the list's fleet overview" do
    defp online(box), do: {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})

    setup do
      a = box_fixture(name: "alpha")
      b = box_fixture(name: "bravo", capabilities: capabilities(vcpus: 10, memory_mib: 32_768))
      online(a)
      online(b)
      vm_fixture(a, requested_at: DateTime.add(DateTime.utc_now(), -120))
      vm_fixture(b, vcpus: 2, memory_mib: 4000, state: "starting")
      %{a: a, b: b}
    end

    test "totals what the boxes offer and what's provisioned of it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes")

      assert has_element?(view, "#fleet-boxes", "2 of 2")
      assert has_element?(view, "#fleet-cores", "28")
      assert has_element?(view, "#fleet-memory", "140 GiB")
      assert has_element?(view, "#fleet-vms", "2")
      assert has_element?(view, "#fleet-vms", "1 running a job")
      assert has_element?(view, "#provisioned-vcpus", "6 / 39")
      assert has_element?(view, "#provisioned-memory", "12.2 / 129 GiB")
      assert has_element?(view, "#provisioned-vcpus-plot")
    end

    test "each box shows its usage, and what its VMs hold of what it offers", %{conn: conn, a: a} do
      box_metric_fixture(a, System.os_time(:second) - 5, cpu_pct: 37.0, mem_used_mib: 20_480)
      {:ok, view, _} = live(conn, ~p"/boxes")

      assert has_element?(view, "#box-#{a.id}-cpu", "37%")
      assert has_element?(view, "#box-#{a.id}-memory", "20.0 of 128 GiB")
      assert has_element?(view, "#box-#{a.id}-vcpus", "4 / 25")
      assert has_element?(view, "#box-#{a.id}-mem-provisioned", "8.1 / 101 GiB")
      assert has_element?(view, "#box-#{a.id}-vms", "1 running a job")
      assert has_element?(view, "#box-#{a.id}-vms", "1 × m")
    end

    test "provisioning updates live as VMs come and go", %{conn: conn, a: a} do
      {:ok, view, _} = live(conn, ~p"/boxes")
      assert has_element?(view, "#box-#{a.id}-vcpus", "4 / 25")

      vm = vm_fixture(a, vcpus: 8, memory_mib: 16_384, state: "requested")
      Phoenix.PubSub.broadcast(Crew.PubSub, "vms", {:vm_changed, vm.id})

      assert has_element?(view, "#box-#{a.id}-vcpus", "12 / 25")
      assert has_element?(view, "#provisioned-vcpus", "14 / 39")
    end

    test "the range is in the URL", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes")
      assert has_element?(view, ~s(#range-30m[aria-current="true"]))

      view |> element("#range-24h") |> render_click()
      assert_patch(view, ~p"/boxes?range=24h")
      assert has_element?(view, ~s(#range-24h[aria-current="true"]))
    end

    test "a box that can't take jobs says why, on its card and at the top", %{conn: conn} do
      bad = box_fixture(name: "truenas", firewall_ok: false)
      online(bad)
      {:ok, view, _} = live(conn, ~p"/boxes")

      assert has_element?(view, "#box-#{bad.id}", "Firewall unverified")
      assert has_element?(view, "#box-#{bad.id}-issues", "Firewall not verified")
      assert has_element?(view, "#boxes-attention", "1 box can't take jobs")
      assert has_element?(view, "#boxes-attention a[href='/boxes/#{bad.id}']", "truenas")
    end

    test "with every box healthy there's no alert", %{conn: conn, a: a} do
      {:ok, view, _} = live(conn, ~p"/boxes")
      refute has_element?(view, "#boxes-attention")
      refute has_element?(view, "#box-#{a.id}-issues")
    end

    test "a drained box isn't an alert, but isn't taking jobs either", %{conn: conn, a: a} do
      a |> Ecto.Changeset.change(draining: true) |> Crew.Repo.update!()
      {:ok, view, _} = live(conn, ~p"/boxes")

      refute has_element?(view, "#boxes-attention")
      assert has_element?(view, "#fleet-boxes", "1 draining")
      refute has_element?(view, "#fleet-boxes", "All taking jobs")
    end
  end

  test "the box page warns when the firewall isn't verified", %{conn: conn} do
    box = box_fixture(name: "truenas", firewall_ok: false)
    {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")

    assert has_element?(view, "#firewall-unverified", "Crew places no jobs on this box")
    assert has_element?(view, "#box-status", "Firewall unverified")
  end

  test "a box that's enrolled but hasn't joined yet shows, live", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/boxes")
    assert has_element?(view, "#boxes-empty")

    {:ok, token} =
      Boxes.create_join_token(Crew.Scope.for_user(user_fixture(role: "admin")), %{
        "box_name" => "fresh",
        "box_type" => "mac-vz"
      })

    {public, _} = CrewProtocol.Auth.generate_keypair()
    {:ok, box} = Boxes.enroll(token, %{"public_key" => Base.encode64(public)})

    assert has_element?(view, "#box-#{box.id}", "fresh")
    assert has_element?(view, "#box-#{box.id}", "No capacity until the agent reports")
    assert has_element?(view, "#boxes-attention", "fresh")
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
      # With its cache VM (§15.6), which the installer makes first.
      assert has_element?(view, "#join-command", "--cache-vm")
      assert has_element?(view, "#cache-vm-note")
      assert [_, token] = Regex.run(~r/--token (cj_[A-Za-z0-9_-]+)/, html)
      {public, _} = CrewProtocol.Auth.generate_keypair()
      assert {:ok, _} = Boxes.enroll(token, %{"public_key" => Base.encode64(public)})
    end

    # The agent checks its updates against it (§20.2).
    test "the mac-vz command gives the agent the release key", %{conn: conn} do
      key = Crew.ImageFixtures.keypair()
      Crew.ImageFixtures.trust(key)
      {:ok, view, _} = live(conn, ~p"/boxes/new")

      view
      |> form("#add-box", %{"box" => %{"box_name" => "m1ultra", "box_type" => "mac-vz"}})
      |> render_submit()

      assert has_element?(view, "#join-command", "--release-key #{Base.encode64(key.public)}")
    end

    test "shows the launcher command for linux-vm and mac-vm", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/boxes/new")

      html =
        view
        |> form("#add-box", %{"box" => %{"box_name" => "m3max", "box_type" => "mac-vm"}})
        |> render_submit()

      assert html =~ "/agent/mac-vm.sh | sudo sh -s -- --token cj_"
      refute has_element?(view, "#ignition-download")
    end

    # A Flatcar VM built by hand, on a host the launcher can't run on
    # (TrueNAS SCALE, say), is still a linux-vm box: nested, unlike
    # linux-metal, which repos pin for isolation (issue #23).
    test "linux-vm shows the launcher command, and the Ignition for a VM built by hand", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/boxes/new")
      view |> form("#add-box", %{"box" => %{"box_type" => "linux-vm"}}) |> render_change()
      refute has_element?(view, "#box_data_disk")

      html =
        view
        |> form("#add-box", %{"box" => %{"box_name" => "nas1", "box_type" => "linux-vm"}})
        |> render_submit()

      # The launcher stays the way in.
      assert [_, token] =
               Regex.run(~r/linux-vm\.sh \| sudo sh -s -- --token (cj_[A-Za-z0-9_-]+)/, html)

      assert has_element?(
               view,
               "#ignition-download[action='/agent/flatcar/ignition'][method='post']"
             )

      assert has_element?(view, "#ignition-download input[name=join_token][value='#{token}']")
      assert has_element?(view, "#ignition-fetch-command", "(umask 077; ")
      assert has_element?(view, "#ignition-fetch-command", "arch=amd64")
      # VirtIO disks: the OS disk is /dev/vda, and the Ignition formats
      # /dev/vdb as the data disk.
      assert has_element?(view, "#hand-built-vm", "/dev/vdb")

      assert has_element?(
               view,
               "#flatcar-install",
               "flatcar-install -d /dev/vda -i crew-nas1.ign"
             )

      refute has_element?(view, "#flatcar-install", "/dev/sda")

      join = Crew.Repo.get_by!(Crew.Boxes.JoinToken, box_name: "nas1")
      assert join.box_type == "linux-vm"
      assert join.data_disk == nil
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
      assert has_element?(view, "#join-command", "(umask 077; ")
      refute render(view) =~ "> crew-rack1.ign"

      # Run it, against a stub curl, over a 0644 file a previous download
      # left: the file it ends with is 0600 all the same.
      [command] = Regex.run(~r/\(umask 077;[^<]*\)/, view |> element("#join-command") |> render())

      command =
        Enum.reduce(
          [
            {"&quot;", ~s(")},
            {"&#34;", ~s(")},
            {"&#39;", "'"},
            {"&gt;", ">"},
            {"&lt;", "<"},
            {"&amp;", "&"}
          ],
          command,
          fn {from, to}, acc -> String.replace(acc, from, to) end
        )

      dir = Path.join(System.tmp_dir!(), "crew-ign-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "bin"))
      on_exit(fn -> File.rm_rf!(dir) end)
      curl = Path.join(dir, "bin/curl")

      File.write!(curl, """
      #!/bin/sh
      while [ $# -gt 0 ]; do [ "$1" = -o ] && echo '{"ignition":{}}' > "$2"; shift; done
      exit 0
      """)

      File.chmod!(curl, 0o755)
      File.write!(Path.join(dir, "crew-rack1.ign"), "old")
      File.chmod!(Path.join(dir, "crew-rack1.ign"), 0o644)

      {_, 0} =
        System.cmd("sh", ["-c", command],
          cd: dir,
          env: [{"PATH", Path.join(dir, "bin") <> ":/usr/bin:/bin"}]
        )

      assert File.read!(Path.join(dir, "crew-rack1.ign")) =~ "ignition"
      assert File.stat!(Path.join(dir, "crew-rack1.ign")).mode |> Bitwise.band(0o777) == 0o600
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
      refute has_element?(view, "#reprovision-install-command")
    end

    test "a linux-vm box's also says how to reinstall a VM built by hand", %{conn: conn} do
      box = box_fixture(type: "linux-vm")
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#reprovision-command", "crew-box reimage")

      assert has_element?(
               view,
               "#reprovision-install-command",
               "flatcar-install -d /dev/vda -i crew-#{box.name}-arm64-reprovision.ign"
             )
    end

    test "a mac-vz box has none", %{conn: conn} do
      box = box_fixture(type: "mac-vz")
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      refute has_element?(view, "#reprovision")
    end
  end

  describe "the agent's version (§20.2)" do
    setup do
      key = Crew.ImageFixtures.keypair()
      Crew.ImageFixtures.trust(key)
      dir = Crew.AgentReleaseFixtures.tmp_dir("box-page-releases")

      for v <- ["0.2.0", "0.3.0"],
          do:
            Crew.AgentReleaseFixtures.write_release(dir, key, v, "darwin-arm64",
              components: ["agent"]
            )

      Crew.Agents.Releases.register_bundle(dir)

      box =
        box_fixture(name: "m4")
        |> Ecto.Changeset.change(os: "darwin", arch: "arm64", agent_version: "0.2.0")
        |> Crew.Repo.update!()

      %{box: box}
    end

    test "says where the box is and what it follows", %{conn: conn, box: box} do
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#agent-running", "0.2.0")
      assert has_element?(view, "#agent-running", "darwin-arm64")
      assert has_element?(view, "#agent-target", "0.3.0")
      assert has_element?(view, "#agent-update-state", "Updates to 0.3.0 when it's back")

      assert has_element?(
               view,
               "#pin-agent-version option[value='']",
               "Follow the newest (0.3.0)"
             )
    end

    test "an admin pins a version, and unpins it", %{conn: conn, box: box} do
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")

      view |> form("#pin-agent", %{"version" => "0.2.0"}) |> render_submit()
      assert render(view) =~ "Pinned m4&#39;s agent to 0.2.0."
      assert has_element?(view, "#agent-target", "0.2.0")
      assert has_element?(view, "#agent", "Pinned to")
      assert has_element?(view, "#agent-update-state", "Up to date")
      assert Boxes.get!(box.id).desired_agent_version == "0.2.0"

      view |> form("#pin-agent", %{"version" => ""}) |> render_submit()
      assert Boxes.get!(box.id).desired_agent_version == nil
      assert has_element?(view, "#agent", "Follows")
    end

    test "a version that failed twice says so, and an admin can retry it", %{conn: conn, box: box} do
      box |> Ecto.Changeset.change(failed_agent_version: "0.3.0") |> Crew.Repo.update!()
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#agent-update-failed", "didn't take on this box twice")

      view |> element("#retry-agent-update") |> render_click()
      refute has_element?(view, "#agent-update-failed")
      assert Boxes.get!(box.id).failed_agent_version == nil
    end

    test "a pinned release whose files aren't here says so, and what to do", %{
      conn: conn,
      box: box
    } do
      box |> Ecto.Changeset.change(desired_agent_version: "0.3.0") |> Crew.Repo.update!()
      File.rm!(Crew.Agents.Releases.get("agent", "0.3.0", "darwin-arm64").path)

      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#agent-update-state", "0.3.0's files aren't here")
      assert has_element?(view, "#agent-files-missing", "crew-agent-0.3.0-darwin-arm64.tar.gz")
      assert has_element?(view, "#agent-files-missing", Crew.Agents.Releases.store_dir())
    end

    test "members see it but can't change it", %{box: box} do
      conn = log_in(build_conn(), user_fixture())
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#agent-target", "0.3.0")
      refute has_element?(view, "#pin-agent")
    end
  end

  describe "reboots (§12.1)" do
    defp flatcar(attrs \\ []) do
      box_fixture(Keyword.merge([type: "linux-metal", name: "rack1"], attrs))
      |> Ecto.Changeset.change(
        can_restart: true,
        boot_id: "11111111-1111-4111-8111-111111111111",
        os_version: "4757.2.3",
        reboot_required: true,
        reboot_packages: ["flatcar-4800.0.0", "tailscale-v1.106.0"]
      )
      |> Crew.Repo.update!()
    end

    defp as_agent(box) do
      {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})
      box
    end

    test "a box that needs one says what's pending, with Flatcar's release notes", %{conn: conn} do
      box = flatcar()
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#reboot", "flatcar-4800.0.0")
      assert has_element?(view, "#reboot", "tailscale-v1.106.0")

      assert has_element?(
               view,
               ~s(#reboot a[href="https://www.flatcar.org/releases#release-4800.0.0"])
             )
    end

    test "Reboot drains the box and, with nothing running, reboots it", %{conn: conn} do
      box = flatcar() |> as_agent()
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      view |> element("#reboot-box") |> render_click()

      assert_receive {:dispatch, %CrewProtocol.Command{type: "box.restart"}}
      assert has_element?(view, "#reboot", "Rebooting")
      assert Boxes.get!(box.id).draining
      refute has_element?(view, "#reboot-box")
    end

    test "Reboot now says how many jobs it cuts short", %{conn: conn} do
      box = flatcar()
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert render(element(view, "#reboot-box-now")) =~ "0 running jobs fail"
    end

    test "a box that can't restart from Crew has no Reboot", %{conn: conn} do
      box = box_fixture(name: "m1")
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      refute has_element?(view, "#reboot-box")
    end

    test "an update that rolled back says so", %{conn: conn} do
      box =
        flatcar()
        |> Ecto.Changeset.change(previous_os_version: "4757.2.3", reboot_required: false)
        |> Crew.Repo.update!()

      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#reboot", "rolled back")
    end

    test "a mac-vz box's cache VM: its pending update, and Reboot cache VM", %{conn: conn} do
      box =
        box_fixture(name: "m1ultra")
        |> Ecto.Changeset.change(
          cache_vm_reboot: %{
            "required" => true,
            "packages" => ["flatcar-4800.0.0"],
            "boot_id" => "c1c1c1c1-1111-4111-8111-111111111111"
          }
        )
        |> Crew.Repo.update!()
        |> as_agent()

      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#cache-vm", "flatcar-4800.0.0")

      # Its crew_cache is updated with a new OS disk and the newest release.
      assert has_element?(view, ~s(#cache-vm a[href="/boxes/#{box.id}/cachevm-reprovision.ign"]))

      assert has_element?(
               view,
               "#cache-vm",
               "sudo crew-box reimage crew-m1ultra-cachevm-reprovision.ign cachevm"
             )

      view |> element("#reboot-cache-vm") |> render_click()

      assert_receive {:dispatch, %CrewProtocol.Command{type: "cachevm.restart"}}
      assert has_element?(view, "#cache-vm", "Restarting")
    end

    test "members see the state but get no buttons" do
      box = flatcar()
      conn = log_in(build_conn(), user_fixture(role: "member"))
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#reboot", "flatcar-4800.0.0")
      refute has_element?(view, "#reboot-box")
      refute has_element?(view, "#reboot-box-now")
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
