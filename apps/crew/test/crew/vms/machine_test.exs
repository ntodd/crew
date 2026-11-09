defmodule Crew.VMs.MachineTest do
  @moduledoc "The full §8.6 transition table, every cell."
  use ExUnit.Case, async: true

  alias Crew.VMs.Machine

  @states ~w(requested starting booted idle busy finished failed)

  defp vm(state, attrs),
    do: Map.merge(%{state: state, fail_reason: nil, job_id: nil, alive: true}, attrs)

  defp t(state, event, attrs \\ %{}), do: Machine.transition(vm(state, attrs), event)

  # The expected outcome per state, `:ignored` where the table is blank.
  defp row(event, cells) do
    for {state, expected} <- Enum.zip(@states, cells) do
      {state, event, expected}
    end
  end

  defp check(rows) do
    for {state, event, expected} <- rows do
      # In the table a busy or finished VM has its job (a 422's busy VM
      # without one is tested on its own).
      result = t(state, event, if(state in ~w(busy finished), do: %{job_id: "job-0"}, else: %{}))

      case expected do
        :ignored ->
          assert result == :ignored,
                 "#{state} + #{inspect(event)}: expected ignored, got #{inspect(result)}"

        {to, reason, effects} ->
          assert {:ok, %{state: ^to, fail_reason: ^reason}, got} = result,
                 "#{state} + #{inspect(event)}"

          assert Enum.sort(got) == Enum.sort(effects),
                 "#{state} + #{inspect(event)}: effects #{inspect(got)}"
      end
    end
  end

  test "JIT config generated, vm.start sent: requested stays" do
    assert {:ok, %{state: "requested"}, [:record_start_op]} = t("requested", :start_sent)
    for s <- @states -- ["requested"], do: assert(t(s, :start_sent) == :ignored)
  end

  test "op.result ok for vm.start" do
    check(
      row({:start_result, :ok}, [
        {"starting", nil, []},
        :ignored,
        :ignored,
        :ignored,
        :ignored,
        :ignored,
        :ignored
      ])
    )
  end

  test "op.result error for vm.start" do
    check(
      row({:start_result, :error}, [
        {"failed", "start_error", [:delete_runner]},
        :ignored,
        :ignored,
        :ignored,
        :ignored,
        :ignored,
        :ignored
      ])
    )
  end

  test "guest fetched payload (vm.state booted)" do
    check(
      row(:booted, [
        {"booted", nil, []},
        {"booted", nil, []},
        :ignored,
        :ignored,
        :ignored,
        :ignored,
        :ignored
      ])
    )
  end

  test "vm.state runner_listening" do
    check(
      row(:runner_listening, [
        {"idle", nil, [:success]},
        {"idle", nil, [:success]},
        {"idle", nil, [:success]},
        :ignored,
        :ignored,
        :ignored,
        :ignored
      ])
    )
  end

  test "workflow_job.in_progress names this VM" do
    j = {:job_started, "job-1"}
    busy = {"busy", nil, [{:link_job, "job-1"}]}

    check(
      row(j, [
        busy,
        busy,
        busy,
        busy,
        :ignored,
        :ignored,
        {"busy", nil, [{:link_job, "job-1"}, :cancel_force_stop]}
      ])
    )
  end

  test "workflow_job.completed names this VM" do
    c = {:job_completed, "job-1"}
    fin = {"finished", nil, [{:link_job, "job-1"}, :arm_finished]}

    check(
      row(c, [
        fin,
        fin,
        fin,
        fin,
        {"finished", nil, [:arm_finished]},
        :ignored,
        {"finished", nil, [{:link_job, "job-1"}, :arm_finished]}
      ])
    )
  end

  test "a VM that went busy on a 422 links the job GitHub names for it" do
    assert {:ok, %{state: "busy", job_id: "job-1"}, [{:link_job, "job-1"}]} =
             t("busy", {:job_started, "job-1"})

    assert {:ok, %{state: "finished", job_id: "job-1"}, [{:link_job, "job-1"}, :arm_finished]} =
             t("busy", {:job_completed, "job-1"})

    # A linked one keeps its job.
    assert t("busy", {:job_started, "job-2"}, %{job_id: "job-1"}) == :ignored

    assert {:ok, %{state: "finished", job_id: "job-1"}, [:arm_finished]} =
             t("busy", {:job_completed, "job-2"}, %{job_id: "job-1"})
  end

  test "a VM that finished before GitHub named its job still links it" do
    # Busy on the guest's hook or a 422, then exited with its cleanup
    # failed: the server is still up, so GitHub's webhooks land here.
    for event <- [{:job_started, "job-1"}, {:job_completed, "job-1"}] do
      assert {:ok, %{state: "finished", job_id: "job-1", alive: false}, [{:link_job, "job-1"}]} =
               t("finished", event, %{alive: false})
    end

    # A linked one keeps its job.
    for event <- [{:job_started, "job-2"}, {:job_completed, "job-2"}],
        do: assert(t("finished", event, %{job_id: "job-1"}) == :ignored)
  end

  test "the guest says its runner took a job: busy, with the job to be named by GitHub" do
    for s <- ~w(requested starting booted idle),
        do: assert({:ok, %{state: "busy", job_id: nil}, []} = t(s, :guest_job_started))

    assert {:ok, %{state: "busy", fail_reason: nil}, [:cancel_force_stop]} =
             t("failed", :guest_job_started, %{fail_reason: "runner_timeout"})

    for s <- ~w(busy finished), do: assert(t(s, :guest_job_started) == :ignored)
  end

  test "vm.exited" do
    assert {:ok, %{state: "failed", fail_reason: "boot_failed"}, [:delete_runner]} =
             t("requested", {:exited, "boot_failed", :ok})

    assert {:ok, %{state: "failed", fail_reason: "boot_failed"}, [:delete_runner]} =
             t("starting", {:exited, "boot_failed", :ok})

    assert {:ok, %{state: "failed", fail_reason: "crashed"}, [:delete_runner]} =
             t("starting", {:exited, "crashed", :ok})

    assert {:ok, %{state: "failed", fail_reason: "crashed"}, [:delete_runner]} =
             t("booted", {:exited, "poweroff", :ok})

    assert {:ok, %{state: "failed", fail_reason: "crashed"}, [:delete_runner]} =
             t("idle", {:exited, "poweroff", :ok})

    assert {:ok, %{state: "finished"}, [:arm_finished]} = t("busy", {:exited, "poweroff", :ok})
    assert {:ok, %{state: "destroyed"}, []} = t("finished", {:exited, "poweroff", :ok})
    assert {:ok, %{state: "destroyed"}, []} = t("failed", {:exited, "crashed", :ok})
    # Cleanup that failed keeps the row, so its allocation stays counted.
    assert {:ok, %{state: "finished", alive: false}, [:cleanup_failed]} =
             t("finished", {:exited, "poweroff", :error})

    assert {:ok, %{state: "failed", alive: false}, [:cleanup_failed]} =
             t("failed", {:exited, "crashed", :error})
  end

  test "a reaped VM's exit is the end of it" do
    assert {:ok, %{state: "destroyed"}, []} =
             t("finished", {:exited, "poweroff", :ok}, %{fail_reason: "reaped"})
  end

  test "box disconnects: a pre-job VM's runner is deleted before it fails as lost" do
    for s <- ~w(requested starting booted idle),
        do: assert({:ok, %{state: ^s}, [{:delete_runner_then, "lost"}]} = t(s, :box_disconnected))

    for s <- ~w(busy finished failed), do: assert(t(s, :box_disconnected) == :ignored)
  end

  test "box revoked: everything is destroyed" do
    for s <- @states, do: assert({:ok, %{state: "destroyed"}, _} = t(s, :box_revoked))
  end

  test "join inventory doesn't list the VM" do
    for s <- ~w(requested starting booted idle),
        do:
          assert(
            {:ok, %{state: "failed", fail_reason: "lost"}, [:delete_runner]} =
              t(s, :inventory_missing)
          )

    assert {:ok, %{state: "finished"}, [:arm_finished]} = t("busy", :inventory_missing)
    assert {:ok, %{state: "destroyed"}, []} = t("finished", :inventory_missing)
    assert {:ok, %{state: "destroyed"}, []} = t("failed", :inventory_missing)
  end

  test "join inventory lists the VM as alive" do
    for s <- ~w(requested starting booted idle busy),
        do: assert(t(s, :inventory_alive) == :ignored)

    assert {:ok, %{state: "finished"}, [{:stop, true}]} = t("finished", :inventory_alive)
    assert {:ok, %{state: "failed"}, [{:stop, true}]} = t("failed", :inventory_alive)
  end

  describe "timeouts delete the runner first" do
    test "requested without a JIT config has no runner yet: it fails at once" do
      assert {:ok, %{state: "failed", fail_reason: "jit_timeout"}, [{:stop, true}]} =
               t("requested", {:timeout, "jit_timeout"})
    end

    test "the others ask GitHub to delete the runner, then decide" do
      for {state, reason} <- [
            {"requested", "agent_timeout"},
            {"starting", "boot_timeout"},
            {"booted", "runner_timeout"}
          ] do
        assert {:ok, %{state: ^state}, [{:delete_runner_then, ^reason}]} =
                 t(state, {:timeout, reason})
      end
    end

    test "204 or 404: the timeout's failure, and a forced stop" do
      for {state, reason} <- [
            {"requested", "agent_timeout"},
            {"starting", "boot_timeout"},
            {"booted", "runner_timeout"},
            {"idle", "lost"}
          ] do
        assert {:ok, %{state: "failed", fail_reason: ^reason}, [{:stop, true}]} =
                 t(state, {:runner_deleted, :gone, reason})
      end
    end

    test "422: the runner has a job, so the VM is busy and the job is fetched" do
      for state <- ~w(requested starting booted idle) do
        assert {:ok, %{state: "busy"}, [:fetch_job]} =
                 t(state, {:runner_deleted, :busy, "boot_timeout"})
      end
    end

    test "a VM that moved on while GitHub answered is left as it is" do
      assert t("busy", {:runner_deleted, :gone, "boot_timeout"}) == :ignored
    end
  end

  describe "reaping (§8.5)" do
    test "an idle VM's runner is deleted first" do
      assert {:ok, %{state: "idle"}, [{:delete_runner_then, "reaped"}]} =
               t("idle", {:reap, "excess"})
    end

    test "gone: the VM is stopped and finishes as reaped" do
      assert {:ok, %{state: "finished", fail_reason: "reaped"}, [{:stop, false}, :arm_finished]} =
               t("idle", {:runner_deleted, :gone, "reaped"})
    end

    test "busy: it took a job meanwhile" do
      assert {:ok, %{state: "busy"}, [:fetch_job]} = t("idle", {:runner_deleted, :busy, "reaped"})
    end

    test "only idle VMs are reaped" do
      for s <- @states -- ["idle"], do: assert(t(s, {:reap, "excess"}) == :ignored)
    end
  end

  test "finished, no vm.exited: stop after the grace, then force" do
    assert {:ok, %{state: "finished"}, [{:stop, false}]} =
             t("finished", {:finished_timer, :grace})

    assert {:ok, %{state: "finished"}, [{:stop, true}]} = t("finished", {:finished_timer, :force})
  end

  test "failed but alive: forced stops until it exits" do
    assert {:ok, %{state: "failed"}, [{:stop, true}]} = t("failed", :failed_alive_tick)
    assert t("failed", :failed_alive_tick, %{alive: false}) == :ignored
  end

  test "the busy deadline" do
    assert {:ok, %{state: "busy"}, [{:stop, true}]} = t("busy", :deadline)
  end

  test "states only move along the table: a destroyed VM ignores everything" do
    for e <- [
          :booted,
          :runner_listening,
          {:exited, "poweroff", :ok},
          :box_disconnected,
          {:job_started, "j"}
        ],
        do: assert(t("destroyed", e) == :ignored)
  end
end
