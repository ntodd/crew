defmodule Crew.VMs.ServerTest do
  @moduledoc "A VM's life through its server (§8.6): GitHub stubbed, the test process as the agent."
  use Crew.VMCase

  alias Crew.Boxes

  setup %{repo: repo, box: box} do
    GitHubStub.stub(github_routes(repo))
    online(box)
    :ok
  end

  describe "a placement" do
    test "registers a runner with the class's labels and sends vm.start with its JIT config", %{
      box: box,
      repo: repo,
      image: image
    } do
      id = place(box, repo)
      vm = VMs.get!(id)
      assert vm.state == "requested"
      assert vm.name =~ ~r/\Acrew-[a-z0-9]{4}-m4-[0-9a-f]{10}\z/

      assert_receive {:jit_requested, body}
      assert body["name"] == vm.name
      assert body["labels"] == ["crew-m"]

      cmd = assert_command("vm.start")
      assert cmd.payload.vm_id == id
      assert cmd.payload.image.id == image.id
      assert cmd.payload.labels == ["crew-m"]
      assert cmd.payload.policy.fork_prs == "refuse"
      assert is_binary(cmd.payload.jit_config)
      # GitHub's JIT configs leave the runner free to update itself; the
      # guest refuses one that is (§13.5 step 7).
      files = cmd.payload.jit_config |> Base.decode64!() |> Jason.decode!()
      assert (files[".runner"] |> Base.decode64!() |> Jason.decode!())["DisableUpdate"] == true

      vm = eventually(fn -> VMs.get!(id).start_op_id && VMs.get!(id) end)
      assert vm.runner_id
      assert vm.start_op_id == cmd.op_id
      # The JIT config is never stored (§6.3).
      refute Repo.get!(Crew.Operations.Operation, cmd.op_id).args["jit_config"] ==
               cmd.payload.jit_config
    end

    test "walks to idle on the agent's events, and a success clears the box's failures", %{
      box: box,
      repo: repo
    } do
      Repo.update!(Ecto.Changeset.change(box, consecutive_failures: 2))
      id = place(box, repo)
      cmd = assert_command("vm.start")
      ack_start(box, cmd)
      assert await_state(id, "starting").alive

      agent_event(box, "vm.state", %{"vm_id" => id, "state" => "booted", "at" => 1})
      await_state(id, "booted")
      agent_event(box, "vm.state", %{"vm_id" => id, "state" => "runner_listening", "at" => 2})
      vm = await_state(id, "idle")

      assert vm.started_at && vm.booted_at && vm.idle_at
      assert Boxes.get!(box.id).consecutive_failures == 0

      kinds =
        Repo.all(
          from e in Crew.VMs.VMEvent, where: e.vm_id == ^id, order_by: e.at, select: e.kind
        )

      assert "start_result" in kinds and "runner_listening" in kinds
    end

    test "a refused vm.start fails it and deletes the runner", %{box: box, repo: repo} do
      id = place(box, repo)
      cmd = assert_command("vm.start")
      ack_start(box, cmd, "error", "no_capacity")

      vm = await_state(id, "failed")
      assert vm.fail_reason == "start_error"

      assert_enqueued(
        worker: Crew.VMs.DeleteRunner,
        args: %{repo_id: repo.id, runner_id: vm.runner_id}
      )

      assert Boxes.get!(box.id).consecutive_failures == 1
    end

    test "image_not_ready doesn't count against the box", %{box: box, repo: repo} do
      id = place(box, repo)
      ack_start(box, assert_command("vm.start"), "error", "image_not_ready")
      assert await_state(id, "failed").fail_reason == "image_not_ready"
      assert Boxes.get!(box.id).consecutive_failures == 0
    end

    test "three failures in a row quarantine the box for 5 minutes", %{box: box, repo: repo} do
      Crew.Activity.subscribe()

      for _ <- 1..3 do
        id = place(box, repo)
        ack_start(box, assert_command("vm.start"), "error", "boom")
        await_state(id, "failed")
      end

      box = Boxes.get!(box.id)
      assert box.quarantined_until
      assert DateTime.diff(box.quarantined_until, DateTime.utc_now()) in 290..300
      assert_receive {:activity, %{kind: "box_quarantined"}}
    end

    test "another box's agent can't report on this VM", %{box: box, repo: repo} do
      id = place(box, repo)
      other = box_fixture(name: "other")

      assert {:error, _} =
               agent_event(other, "vm.state", %{
                 "vm_id" => id,
                 "state" => "runner_listening",
                 "at" => 1
               })

      assert VMs.get!(id).state == "requested"
    end
  end

  describe "jobs" do
    test "an in_progress naming the VM's runner makes it busy and links the job", %{
      box: box,
      repo: repo
    } do
      job = queued_job(repo, id: 501)
      id = place(box, repo)
      vm = to_idle(box, id)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 501,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: vm.name
          )
        )

      vm = await_state(id, "busy")
      assert vm.job_id == job.id

      # The link is written just after the VM's transition.
      job = eventually(fn -> (j = Jobs.get_job!(job.id)) && j.vm_id && j end)
      assert job.vm_id == id
      refute job.taken_cross_class
      assert eventually(fn -> Map.has_key?(Boxes.get!(box.id).last_repo_ran_at, repo.id) end)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 501,
            run_id: job.github_run_id,
            status: "completed",
            conclusion: "success",
            runner_name: vm.name
          )
        )

      assert await_state(id, "finished").finished_at
    end

    test "a busy VM whose guest powers off is finished and then destroyed at once", %{
      box: box,
      repo: repo
    } do
      job = queued_job(repo, id: 505)
      id = place(box, repo)
      vm = to_idle(box, id)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 505,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: vm.name
          )
        )

      await_state(id, "busy")

      agent_event(box, "vm.exited", %{"vm_id" => id, "reason" => "poweroff", "cleanup" => "ok"})
      vm = await_state(id, "destroyed")
      assert vm.finished_at

      # The completed webhook after that changes nothing.
      {:ok, job} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 505,
            run_id: job.github_run_id,
            status: "completed",
            conclusion: "success",
            runner_name: vm.name
          )
        )

      assert job.vm_id == id
      assert VMs.get!(id).state == "destroyed"
    end

    test "the job's summary is final once its VM is destroyed, after its completed", %{
      box: box,
      repo: repo
    } do
      job = queued_job(repo, id: 506)
      id = place(box, repo)
      vm = to_idle(box, id)
      started = workflow_job_payload(repo, id: 506, run_id: job.github_run_id)

      {:ok, _} =
        Jobs.handle_workflow_job(
          put_in(started, ["workflow_job", "status"], "in_progress")
          |> put_in(["workflow_job", "runner_name"], vm.name)
        )

      await_state(id, "busy")
      t0 = DateTime.to_unix(~U[2026-11-03 10:00:05Z])
      vm_metric_fixture(VMs.get!(id), t0 + 5, mem_used_mib: 1500)

      {:ok, done} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 506,
            run_id: job.github_run_id,
            status: "completed",
            conclusion: "success",
            completed_at: "2026-11-03T10:00:20Z",
            runner_name: vm.name
          )
        )

      assert %{peak_mem_mib: 1500, coverage: nil} = Repo.get!(Jobs.Job, done.id)

      # The last reading lands before the VM goes.
      vm_metric_fixture(VMs.get!(id), t0 + 20, mem_used_mib: 4000)
      agent_event(box, "vm.exited", %{"vm_id" => id, "reason" => "poweroff", "cleanup" => "ok"})
      await_state(id, "destroyed")

      assert %{peak_mem_mib: 4000, coverage: coverage} =
               eventually(fn ->
                 j = Repo.get!(Jobs.Job, done.id)
                 j.coverage && j
               end)

      assert is_float(coverage)
    end

    test "a busy VM whose cleanup failed stays finished, holding its allocation", %{
      box: box,
      repo: repo
    } do
      job = queued_job(repo, id: 506)
      id = place(box, repo)
      vm = to_idle(box, id)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 506,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: vm.name
          )
        )

      await_state(id, "busy")

      agent_event(box, "vm.exited", %{"vm_id" => id, "reason" => "poweroff", "cleanup" => "error"})

      vm = await_state(id, "finished")
      refute vm.alive
      Process.sleep(50)
      assert VMs.get!(id).state == "finished"
    end

    test "a short job's exit can come before GitHub's webhooks", %{box: box, repo: repo} do
      job = queued_job(repo, id: 507)
      id = place(box, repo)
      vm = to_idle(box, id)

      agent_event(box, "vm.state", %{"vm_id" => id, "state" => "job_started", "at" => 3})
      await_state(id, "busy")
      agent_event(box, "vm.state", %{"vm_id" => id, "state" => "job_finished", "at" => 4})
      agent_event(box, "vm.exited", %{"vm_id" => id, "reason" => "poweroff", "cleanup" => "ok"})
      vm_after = await_state(id, "destroyed")
      assert vm_after.fail_reason == nil
      assert Boxes.get!(box.id).consecutive_failures == 0
      eventually(fn -> Server.whereis(id) == nil end)

      for status <- ["in_progress", "completed"] do
        {:ok, _} =
          Jobs.handle_workflow_job(
            workflow_job_payload(repo,
              id: 507,
              run_id: job.github_run_id,
              status: status,
              conclusion: if(status == "completed", do: "success"),
              runner_name: vm.name
            )
          )
      end

      assert Jobs.get_job!(job.id).vm_id == id
      assert VMs.get!(id).job_id == job.id
      assert VMs.get!(id).state == "destroyed"
    end

    test "a VM busy on the guest's hook that exits with a cleanup error still links its job",
         %{box: box, repo: repo} do
      job = queued_job(repo, id: 508)
      id = place(box, repo)
      vm = to_idle(box, id)

      agent_event(box, "vm.state", %{"vm_id" => id, "state" => "job_started", "at" => 3})
      await_state(id, "busy")

      agent_event(box, "vm.exited", %{"vm_id" => id, "reason" => "poweroff", "cleanup" => "error"})

      await_state(id, "finished")

      for status <- ["in_progress", "completed"] do
        {:ok, _} =
          Jobs.handle_workflow_job(
            workflow_job_payload(repo,
              id: 508,
              run_id: job.github_run_id,
              status: status,
              conclusion: if(status == "completed", do: "success"),
              runner_name: vm.name
            )
          )
      end

      assert eventually(fn -> VMs.get!(id).job_id end) == job.id
      assert eventually(fn -> Jobs.get_job!(job.id).vm_id end) == id
      assert VMs.get!(id).state == "finished"
    end

    test "a job taken across classes is flagged", %{box: box, repo: repo} do
      job = queued_job(repo, id: 502, labels: ["crew-m"])
      id = place(box, repo, label_key: ["crew-m", "self-hosted"])
      vm = to_idle(box, id)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 502,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: vm.name
          )
        )

      await_state(id, "busy")
      assert eventually(fn -> Jobs.get_job!(job.id).taken_cross_class end)
    end

    test "a spare VM that takes a regular alias job stays spare, and the job regular", %{
      box: box,
      repo: repo
    } do
      Repo.insert!(%Crew.Sizes.LabelAlias{
        labels: ["self-hosted"],
        labels_key: "self-hosted",
        size_id: size_m().id,
        arch: "any"
      })

      job = queued_job(repo, id: 504, labels: ["self-hosted"])
      assert job.classification == "ours" and job.aliased and not job.spare

      id = place(box, repo, label_key: ["crew-m-spare", "self-hosted"], spare: true)
      vm = to_idle(box, id)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 504,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: vm.name
          )
        )

      assert await_state(id, "busy").spare
      assert eventually(fn -> Jobs.get_job!(job.id).taken_cross_class end)
      refute Jobs.get_job!(job.id).spare
    end

    test "another deployment's runner name is left alone", %{repo: repo} do
      job = queued_job(repo, id: 503)

      {:ok, job} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 503,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: "crew-zzzz-m4-0123456789"
          )
        )

      assert job.vm_id == nil
    end

    test "a refused fork PR's job on a Crew runner is stopped at once", %{box: box, repo: repo} do
      Crew.Activity.subscribe()
      run_id = 9001

      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: run_id, head_repo: "evil/fork", event: "pull_request")
        )

      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 504, run_id: run_id))
      assert job.unsatisfiable_reason == "fork PRs are refused on this repo"

      id = place(box, repo)
      vm = to_idle(box, id)

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 504,
            run_id: run_id,
            status: "in_progress",
            runner_name: vm.name
          )
        )

      stop = assert_command("vm.stop")
      assert stop.payload.vm_id == id
      assert stop.payload.reason == "refused"
      assert stop.payload.force
      assert_receive {:activity, %{kind: "fork_refused"}}
    end
  end

  describe "timeouts (§8.6)" do
    @tag timers: %{ack: 50}
    test "no ack: the runner is deleted first, then the VM fails with a forced stop", %{
      box: box,
      repo: repo
    } do
      id = place(box, repo)
      assert_command("vm.start")
      assert_receive {:runner_deleted, _}, 1_000
      vm = await_state(id, "failed")
      assert vm.fail_reason == "agent_timeout"
      stop = assert_command("vm.stop")
      assert stop.payload.force
    end

    @tag timers: %{ack: 50}
    test "a spare VM times out like any other", %{box: box, repo: repo} do
      id = place(box, repo, label_key: ["crew-m-spare"], spare: true)
      assert_command("vm.start")
      assert_receive {:runner_deleted, _}, 1_000
      assert await_state(id, "failed").fail_reason == "agent_timeout"
      assert assert_command("vm.stop").payload.force
    end

    @tag timers: %{boot: 50}
    test "a 422 means the runner has a job: the VM is busy", %{box: box, repo: repo} do
      GitHubStub.stub(github_routes(repo, delete_status: 422))
      id = place(box, repo)
      ack_start(box, assert_command("vm.start"))
      await_state(id, "starting")
      assert_receive {:runner_deleted, _}, 1_000
      await_state(id, "busy")
    end

    @tag timers: %{jit: 50, jit_retry: 10}
    test "no JIT config: jit_timeout", %{box: box, repo: repo} do
      GitHubStub.stub(
        Map.put(
          github_routes(repo),
          {"POST", "/repos/#{repo.full_name}/actions/runners/generate-jitconfig"},
          {500, %{}}
        )
      )

      id = place(box, repo)
      assert await_state(id, "failed").fail_reason == "jit_timeout"
      refute_received {:dispatch, %{type: "vm.start"}}
    end
  end

  describe "review fixes" do
    test "the busy deadline fires once, then retries with a forced stop and an inventory", %{
      box: box,
      repo: repo
    } do
      Application.put_env(:crew, :job_max_s, 0)
      Application.put_env(:crew, :vm_timers_ms, %{deadline_retry: 150})
      on_exit(fn -> Application.delete_env(:crew, :job_max_s) end)

      job = queued_job(repo, id: 601)
      id = place(box, repo)
      ack_start(box, assert_command("vm.start"))
      await_state(id, "starting")
      # in_progress before runner_listening: the boot timer gives way to the deadline.
      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 601,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: VMs.get!(id).name
          )
        )

      await_state(id, "busy")

      stop = assert_command("vm.stop")
      assert stop.payload.reason == "deadline" and stop.payload.force
      refute_receive {:dispatch, %{type: "vm.stop"}}, 100
      assert_command("vm.stop", 500)
      assert_command("box.inventory", 500)
    end

    test "a crashed server comes back from the database, without a second JIT config", %{
      box: box,
      repo: repo
    } do
      id = place(box, repo)
      assert_receive {:jit_requested, _}
      assert_command("vm.start")
      eventually(fn -> VMs.get!(id).start_op_id end)

      Process.exit(Server.whereis(id), :kill)
      assert await_state(id, "failed").fail_reason == "cp_restart"
      refute_received {:jit_requested, _}
    end

    test "servers crashing one after another each come back, and the others stay up", %{
      box: box,
      repo: repo
    } do
      bystander = place(box, repo)
      assert_command("vm.start")
      pid = Server.whereis(bystander)

      for _ <- 1..5 do
        id = place(box, repo)
        assert_command("vm.start")
        eventually(fn -> VMs.get!(id).start_op_id end)
        Process.exit(Server.whereis(id), :kill)
        assert await_state(id, "failed").fail_reason == "cp_restart"
      end

      assert Server.whereis(bystander) == pid
    end

    @tag timers: %{boot: 100}
    test "a crashed server rebuilds its timers", %{box: box, repo: repo} do
      id = place(box, repo)
      ack_start(box, assert_command("vm.start"))
      await_state(id, "starting")
      pid = Server.whereis(id)
      Process.exit(pid, :kill)
      eventually(fn -> Server.whereis(id) not in [nil, pid] end)
      assert await_state(id, "failed").fail_reason == "boot_timeout"
    end

    test "the JIT config isn't in the server's status, which crash reports print", %{
      box: box,
      repo: repo
    } do
      id = place(box, repo)
      cmd = assert_command("vm.start")

      status =
        id
        |> Server.whereis()
        |> :sys.get_status()
        |> inspect(limit: :infinity, printable_limit: :infinity)

      refute status =~ cmd.payload.jit_config
      assert status =~ "redacted"
    end

    test "a pre-job exit with cleanup done frees the allocation at once", %{box: box, repo: repo} do
      id = place(box, repo)
      ack_start(box, assert_command("vm.start"))
      await_state(id, "starting")

      agent_event(box, "vm.exited", %{"vm_id" => id, "reason" => "boot_failed", "cleanup" => "ok"})

      vm = await_state(id, "destroyed")
      assert vm.fail_reason == "boot_failed"
      assert vm.failed_at
      assert Crew.Boxes.get!(box.id).consecutive_failures == 1
    end

    @tag timers: %{boot: 50}
    test "a VM made busy by a 422 links the job when GitHub names it", %{box: box, repo: repo} do
      GitHubStub.stub(github_routes(repo, delete_status: 422))
      job = queued_job(repo, id: 602)
      id = place(box, repo)
      ack_start(box, assert_command("vm.start"))
      assert await_state(id, "busy").job_id == nil

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 602,
            run_id: job.github_run_id,
            status: "in_progress",
            runner_name: VMs.get!(id).name
          )
        )

      assert eventually(fn -> VMs.get!(id).job_id end) == job.id
      assert eventually(fn -> Jobs.get_job!(job.id).vm_id end) == id
    end

    test "a VM's class accounting leaves the scheduler's excess_since alone", %{
      box: box,
      repo: repo
    } do
      at = DateTime.add(DateTime.utc_now(), -42) |> DateTime.truncate(:microsecond)

      Repo.insert!(%Crew.Scheduler.ClassState{
        repo_id: repo.id,
        class_hash: VM.class_hash(["crew-m"]),
        class_key: ["crew-m"],
        excess_since: at,
        updated_at: DateTime.utc_now()
      })

      id = place(box, repo)
      ack_start(box, assert_command("vm.start"), "error", "boom")
      await_state(id, "failed")

      cs =
        eventually(fn ->
          (cs = Repo.get_by!(Crew.Scheduler.ClassState, repo_id: repo.id)) &&
            cs.consecutive_failures == 1 && cs
        end)

      assert cs.last_error == "start_error"
      assert DateTime.compare(cs.excess_since, at) == :eq
    end

    test "simultaneous failures are all counted, and the fifth backs the class off", %{
      box: box,
      repo: repo
    } do
      ids = for _ <- 1..5, do: place(box, repo)
      cmds = for _ <- ids, do: assert_command("vm.start")
      Enum.each(cmds, &ack_start(box, &1, "error", "boom"))
      for id <- ids, do: await_state(id, "failed")

      assert eventually(fn ->
               (cs = Repo.get_by(Crew.Scheduler.ClassState, repo_id: repo.id)) &&
                 cs.consecutive_failures == 5
             end)

      assert eventually(fn ->
               Repo.get_by(Crew.Scheduler.ClassState, repo_id: repo.id).backoff_until
             end)
    end
  end

  describe "a failed VM the agent never started" do
    @tag timers: %{ack: 30, first_check: 20}
    test "is destroyed once the box's inventory doesn't list it", %{box: box, repo: repo} do
      id = place(box, repo)
      assert_command("vm.start")
      await_state(id, "failed")
      assert_command("box.inventory")

      agent_event(box, "box.inventory", %{"vms" => [], "images" => []})
      assert await_state(id, "destroyed").destroyed_at
      eventually(fn -> Server.whereis(id) == nil end)
    end
  end

  describe "reaping (§8.5)" do
    test "an idle VM's runner is deleted, then it's stopped gracefully and finishes as reaped", %{
      box: box,
      repo: repo
    } do
      id = place(box, repo)
      to_idle(box, id)

      VMs.reap(id, :excess)
      assert_receive {:runner_deleted, _}
      vm = await_state(id, "finished")
      assert vm.fail_reason == "reaped"
      stop = assert_command("vm.stop")
      refute stop.payload.force
      assert stop.payload.reason == "reaped"

      agent_event(box, "vm.exited", %{"vm_id" => id, "reason" => "poweroff", "cleanup" => "ok"})
      await_state(id, "destroyed")
    end

    test "a spare VM is reaped like any other", %{box: box, repo: repo} do
      id = place(box, repo, label_key: ["crew-m-spare"], spare: true)
      to_idle(box, id)

      VMs.reap(id, :excess)
      assert_receive {:runner_deleted, _}
      vm = await_state(id, "finished")
      assert vm.fail_reason == "reaped" and vm.spare
    end

    test "two idle_max reaps in a row stall the class", %{box: box, repo: repo} do
      Crew.Activity.subscribe()

      for _ <- 1..2 do
        id = place(box, repo)
        to_idle(box, id)
        VMs.reap(id, :idle_max)
        await_state(id, "finished")
      end

      cs =
        Repo.get_by!(Crew.Scheduler.ClassState,
          repo_id: repo.id,
          class_hash: VM.class_hash(["crew-m"])
        )

      assert cs.stalled_until
      assert DateTime.diff(cs.stalled_until, DateTime.utc_now()) in 590..600
      assert_receive {:activity, %{kind: "class_stalled"}}
    end
  end

  describe "the box's link" do
    test "a disconnect fails a requested VM as lost", %{box: box, repo: repo} do
      id = place(box, repo)
      assert_command("vm.start")
      VMs.agent_left(box.id)
      assert await_state(id, "failed").fail_reason == "lost"
    end

    test "a revoked box's VMs are destroyed", %{box: box, repo: repo} do
      id = place(box, repo)
      to_idle(box, id)
      VMs.box_revoked(box.id)
      await_state(id, "destroyed")
    end

    test "the join inventory: missing VMs are lost, unknown live ones are stopped", %{
      box: box,
      repo: repo
    } do
      id = place(box, repo)
      to_idle(box, id)
      stranger = CrewProtocol.uuid7()

      agent_event(box, "box.inventory", %{
        "vms" => [%{"vm_id" => stranger, "alive" => true}],
        "images" => []
      })

      # Lost, and not on the box: nothing holds its allocation.
      vm = await_state(id, "destroyed")
      assert vm.fail_reason == "lost"
      assert vm.failed_at
      stop = assert_command("vm.stop")
      assert stop.payload.vm_id == stranger
      assert stop.payload.force
    end
  end

  describe "a control plane restart" do
    test "a requested VM gets its runner deleted and fails as cp_restart", %{box: box, repo: repo} do
      id = place(box, repo)
      assert_command("vm.start")
      vm = eventually(fn -> VMs.get!(id).start_op_id && VMs.get!(id) end)
      pid = Server.whereis(id)
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Crew.VMs.Supervisor, pid)
      assert_receive {:DOWN, ^ref, _, _, _}

      VMs.boot_servers()
      assert await_state(id, "failed").fail_reason == "cp_restart"

      assert_enqueued(
        worker: Crew.VMs.DeleteRunner,
        args: %{repo_id: repo.id, runner_id: vm.runner_id}
      )
    end

    test "an idle VM is adopted as it was", %{box: box, repo: repo} do
      id = place(box, repo)
      to_idle(box, id)
      pid = Server.whereis(id)
      DynamicSupervisor.terminate_child(Crew.VMs.Supervisor, pid)
      VMs.boot_servers()
      new = eventually(fn -> Server.whereis(id) end)
      assert new != pid
      assert VMs.get!(id).state == "idle"
    end
  end
end
