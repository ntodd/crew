defmodule CrewWeb.BoxControlsTest do
  @moduledoc "A box page's admin controls (§17.3): drain, quarantine, overrides, kill a VM, images."
  use CrewWeb.ConnCase

  import Ecto.Query

  alias Crew.{Boxes, Repo}

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")
    box = box_fixture(name: "m4")
    %{conn: log_in(conn, admin), box: box}
  end

  defp audited?(action), do: Repo.exists?(from e in Crew.Audit.Event, where: e.action == ^action)

  test "drain and undrain, audited", %{conn: conn, box: box} do
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    view |> element("#drain") |> render_click()
    assert Boxes.get!(box.id).draining
    assert has_element?(view, "#box-status", "Draining")
    view |> element("#undrain") |> render_click()
    refute Boxes.get!(box.id).draining
    assert audited?("box.drain") and audited?("box.undrain")
  end

  test "clearing a quarantine", %{conn: conn, box: box} do
    Repo.update!(
      Ecto.Changeset.change(box,
        quarantined_until: DateTime.add(DateTime.utc_now(), 300),
        consecutive_failures: 0
      )
    )

    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    view |> element("#clear-quarantine") |> render_click()
    assert Boxes.get!(box.id).quarantined_until == nil
    assert audited?("box.clear_quarantine")
  end

  test "capacity overrides, checked and audited", %{conn: conn, box: box} do
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")

    view |> form("#overrides", box: %{cpu_overcommit: "9", max_vms: "4"}) |> render_submit()
    assert render(view) =~ "must be"
    assert Boxes.get!(box.id).cpu_overcommit == 1.5

    view
    |> form("#overrides",
      box: %{
        cpu_overcommit: "1.0",
        max_vms: "4",
        reserve_vcpus: "2",
        allocatable_memory_mib_override: ""
      }
    )
    |> render_submit()

    box = Boxes.get!(box.id)
    assert box.cpu_overcommit == 1.0 and box.max_vms == 4 and box.reserve_vcpus == 2
    assert audited?("box.overrides")
  end

  test "killing a VM sends a forced stop, audited", %{conn: conn, box: box} do
    repo = repo_fixture(name: "web")
    {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})
    size = Repo.get_by!(Crew.Sizes.Size, name: "m")

    [vm] =
      Crew.VMs.create_placements([
        %{class: {repo.id, ["crew-m"]}, box: box, size: size, image_id: nil}
      ])

    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    view |> element("#kill-#{vm.id}") |> render_click()

    assert_receive {:dispatch,
                    %CrewProtocol.Command{
                      type: "vm.stop",
                      payload: %{vm_id: id, force: true, reason: "admin"}
                    }},
                   1_000

    assert id == vm.id
    assert audited?("vm.kill")
    Crew.VMCase.stop_vm_servers()
  end

  test "the box's images and their states", %{conn: conn, box: box} do
    Crew.Images.register_dev_images()
    image = Repo.get_by!(Crew.Images.Image, arch: "arm64")
    Crew.Images.put_box_state(box.id, image.id, "ready")
    {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
    assert has_element?(view, "#images", "0.0.0-dev")
    assert has_element?(view, "#images", "ready")
  end

  test "members see no controls, and their events do nothing", %{box: box} do
    member = user_fixture()
    {:ok, view, _} = live(log_in(build_conn(), member), ~p"/boxes/#{box.id}")
    refute has_element?(view, "#drain")
    refute has_element?(view, "#overrides")
    render_click(view, "drain", %{})
    refute Boxes.get!(box.id).draining
  end
end
