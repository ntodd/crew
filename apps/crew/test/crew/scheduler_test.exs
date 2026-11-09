defmodule Crew.SchedulerTest do
  @moduledoc "A scheduling pass against the database: snapshot, plan, apply (§8.3)."
  use Crew.VMCase

  setup %{repo: repo} do
    GitHubStub.stub(github_routes(repo))
    :ok
  end

  describe "the snapshot" do
    test "uses the smaller of the pinned and reported capabilities, and the larger overhead", %{
      box: box
    } do
      Repo.update!(
        Ecto.Changeset.change(box,
          capabilities: capabilities(vcpus: 10, memory_mib: 200_000, vmm_overhead_mib: 64),
          pinned_capabilities: capabilities(vcpus: 18, memory_mib: 100_000, vmm_overhead_mib: 128)
        )
      )

      [b] = Scheduler.snapshot().boxes
      assert b.caps.vcpus == 10
      assert b.caps.memory_mib == 100_000
      assert b.caps.vmm_overhead_mib == 128
    end

    test "a box that hasn't reported capabilities isn't in it", %{box: box} do
      Repo.update!(Ecto.Changeset.change(box, pinned_capabilities: nil))
      assert Scheduler.snapshot().boxes == []
    end

    test "only queued Crew jobs past the fork check are demand", %{repo: repo} do
      job = queued_job(repo, id: 11)

      {:ok, _} =
        Jobs.handle_workflow_job(workflow_job_payload(repo, id: 12, labels: ["ubuntu-latest"]))

      started = queued_job(repo, id: 13)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: 13, run_id: started.github_run_id, status: "in_progress")
        )

      assert [%{id: id, arch: :any, class: {_, ["crew-m"]}}] = Scheduler.snapshot().jobs
      assert id == job.id
    end

    test "carries each job's and VM's tier", %{box: box, repo: repo} do
      regular = queued_job(repo, id: 14)
      spare = queued_job(repo, id: 15, labels: ["crew-m-spare"])
      vm_fixture(box, repo_id: repo.id, spare: true, state: "idle")
      vm_fixture(box, repo_id: repo.id, state: "idle")

      snap = Scheduler.snapshot()
      tiers = Map.new(snap.jobs, &{&1.id, &1.spare})
      assert tiers == %{regular.id => false, spare.id => true}
      assert snap.vms |> Enum.map(& &1.spare) |> Enum.sort() == [false, true]
    end

    test "uses the box's latest free VM area", %{box: box} do
      online(box)

      agent_event(box, "box.metrics", %{
        "t" => System.os_time(:second),
        "cpu_pct" => 1.0,
        "mem_used_mib" => 1,
        "mem_total_mib" => 2,
        "disk_used_mib" => 1,
        "disk_total_mib" => 2,
        "vm_area_free_mib" => 1234
      })

      assert [%{vm_area_free_mib: 1234}] = Scheduler.snapshot().boxes
    end
  end

  describe "a pass" do
    test "places a VM for a queued job on an online box, once", %{box: box, repo: repo} do
      online(box)
      job = queued_job(repo, id: 21)

      Scheduler.pass()
      assert [vm] = VMs.list_live()
      assert vm.box_id == box.id
      assert vm.class_key == ["crew-m"]
      assert Jobs.get_job!(job.id).wait_reason == "booting a runner on m4"
      assert_command("vm.start")

      # The requested VM is the class's supply now, and the job keeps its
      # reason until GitHub hands it to a runner.
      Scheduler.pass()
      assert length(VMs.list_live()) == 1
      assert Jobs.get_job!(job.id).wait_reason == "booting a runner on m4"
    end

    test "a spare job's VM is written spare, and a regular job's isn't", %{
      box: box,
      repo: repo
    } do
      online(box)
      spare = queued_job(repo, id: 25, labels: ["crew-m-spare"])
      regular = queued_job(repo, id: 26)

      actions = Scheduler.pass()
      tiers = for {:place, p} <- actions, into: %{}, do: {p.job_id, p.spare}
      assert tiers == %{spare.id => true, regular.id => false}

      assert VMs.list_live() |> Enum.map(&{&1.class_key, &1.spare}) |> Enum.sort() == [
               {["crew-m"], false},
               {["crew-m-spare"], true}
             ]
    end

    test "with no box online, the job waits with a reason", %{repo: repo} do
      job = queued_job(repo, id: 22)
      Scheduler.pass()
      assert VMs.list_live() == []
      assert Jobs.get_job!(job.id).blocked_reason == "the only boxes that fit are offline"
    end

    test "with no boxes, the job is blocked", %{box: box, repo: repo} do
      Repo.update!(Ecto.Changeset.change(box, revoked_at: DateTime.utc_now()))
      job = queued_job(repo, id: 23)
      Scheduler.pass()
      assert Jobs.get_job!(job.id).blocked_reason == "no boxes enrolled"
    end

    test "a box missing its arch's default image is sent image.prepare, once", %{
      box: box,
      image: image
    } do
      Repo.delete_all(Crew.Images.BoxImage)
      online(box)

      Scheduler.pass()
      cmd = assert_command("image.prepare")
      assert cmd.payload.image.id == image.id
      assert [%{state: "downloading"}] = Crew.Images.box_images(box.id)

      Scheduler.pass()
      refute_receive {:dispatch, %{type: "image.prepare"}}, 50
    end

    test "an excess idle VM is reaped after the grace", %{box: box, repo: repo} do
      Application.put_env(:crew, :idle_grace_s, 0)
      on_exit(fn -> Application.delete_env(:crew, :idle_grace_s) end)
      online(box)
      id = place(box, repo)
      to_idle(box, id)

      # The first pass notes the excess, the next reaps it.
      Scheduler.pass()
      Scheduler.pass()
      assert_receive {:runner_deleted, _}
      assert await_state(id, "finished").fail_reason == "reaped"
    end

    test "poke runs a pass", %{box: box, repo: repo} do
      online(box)
      queued_job(repo, id: 24)
      start_supervised!(Crew.Scheduler)
      Scheduler.poke()
      eventually(fn -> VMs.list_live() != [] end)
    end
  end

  describe "the label tester" do
    test "quoted YAML labels parse" do
      assert %{result: {:ours, _}, key: ["crew-m", "self-hosted"]} =
               Scheduler.label_test(~s(["self-hosted", "crew-m"]))

      assert %{result: {:ours, _}} = Scheduler.label_test("runs-on: [ 'crew-m' ]")
      assert %{key: ["crew-m", "linux"]} = Scheduler.label_test("- crew-m\n- linux")
    end
  end
end
