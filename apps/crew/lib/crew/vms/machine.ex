defmodule Crew.VMs.Machine do
  @moduledoc """
  The VM lifecycle (§8.6) as a pure function:
  `transition(vm, event) -> {:ok, vm, effects} | :ignored`.

  States: `requested → starting → booted → idle → busy → finished →
  destroyed`, and `failed → destroyed`. Anything the table doesn't list
  is recorded by the caller and otherwise ignored.

  Besides §8.6's events, `:guest_job_started` is the guest's own
  `job_started`: the VM is busy before GitHub's webhook names the job.

  Effects the server carries out:
  - `:record_start_op`, `:delete_runner`, `{:delete_runner_then, reason}`
    (the result comes back as `{:runner_deleted, :gone | :busy, reason}`)
  - `{:stop, force}`, `:fetch_job`, `{:link_job, job_id}`,
    `:cancel_force_stop`, `:arm_finished`, `:success`, `:cleanup_failed`
  """

  @pre_job ~w(requested starting booted idle)

  @type vm :: %{
          state: String.t(),
          fail_reason: String.t() | nil,
          job_id: term(),
          alive: boolean()
        }

  @spec transition(vm, term()) :: {:ok, vm, [term()]} | :ignored
  def transition(%{state: "destroyed"}, _event), do: :ignored

  # JIT config generated and vm.start sent.
  def transition(%{state: "requested"} = vm, :start_sent), do: {:ok, vm, [:record_start_op]}

  def transition(%{state: "requested"} = vm, {:start_result, :ok}), do: to(vm, "starting")

  def transition(%{state: "requested"} = vm, {:start_result, :error}),
    do: fail(vm, "start_error", [:delete_runner])

  # The guest fetched its payload.
  def transition(%{state: s} = vm, :booted) when s in ["requested", "starting"],
    do: to(vm, "booted")

  def transition(%{state: s} = vm, :runner_listening)
      when s in ["requested", "starting", "booted"],
      do: to(vm, "idle", [:success])

  def transition(%{state: s} = vm, {:job_started, job_id}) when s in @pre_job,
    do: to(%{vm | job_id: job_id}, "busy", [{:link_job, job_id}])

  # The guest's job-started hook: the runner took a job, which GitHub's
  # in_progress names (and links) when it comes, maybe after the VM has
  # exited. A failed VM that took one is kept, as for an in_progress.
  def transition(%{state: s} = vm, :guest_job_started) when s in @pre_job, do: to(vm, "busy")

  def transition(%{state: "failed"} = vm, :guest_job_started),
    do: {:ok, %{vm | state: "busy", fail_reason: nil}, [:cancel_force_stop]}

  # Busy from a 422 (the runner had a job Crew hadn't seen yet): the job
  # GitHub names for it is linked.
  def transition(%{state: "busy", job_id: nil} = vm, {:job_started, job_id}),
    do: {:ok, %{vm | job_id: job_id}, [{:link_job, job_id}]}

  def transition(%{state: "busy", job_id: nil} = vm, {:job_completed, job_id}),
    do: {:ok, %{vm | state: "finished", job_id: job_id}, [{:link_job, job_id}, :arm_finished]}

  # Failed but alive: the runner took a job before its delete landed.
  def transition(%{state: "failed"} = vm, {:job_started, job_id}),
    do:
      {:ok, %{vm | state: "busy", fail_reason: nil, job_id: job_id},
       [{:link_job, job_id}, :cancel_force_stop]}

  def transition(%{state: s} = vm, {:job_completed, job_id}) when s in @pre_job or s == "failed",
    do:
      {:ok, %{vm | state: "finished", fail_reason: nil, job_id: job_id},
       [{:link_job, job_id}, :arm_finished]}

  def transition(%{state: "busy"} = vm, {:job_completed, _job_id}),
    do: to(vm, "finished", [:arm_finished])

  # vm.exited: the VMM is gone and cleanup has run.
  def transition(%{state: "requested"} = vm, {:exited, _reason, _cleanup}),
    do: fail(vm, "boot_failed", [:delete_runner])

  def transition(%{state: "starting"} = vm, {:exited, reason, _cleanup}),
    do:
      fail(vm, if(reason == "boot_failed", do: "boot_failed", else: "crashed"), [:delete_runner])

  def transition(%{state: s} = vm, {:exited, _reason, _cleanup}) when s in ["booted", "idle"],
    do: fail(vm, "crashed", [:delete_runner])

  def transition(%{state: "busy"} = vm, {:exited, _reason, _cleanup}),
    do: {:ok, %{vm | state: "finished", alive: false}, [:arm_finished]}

  def transition(%{state: s} = vm, {:exited, _reason, :ok}) when s in ["finished", "failed"],
    do: {:ok, %{vm | state: "destroyed", alive: false}, []}

  def transition(%{state: s} = vm, {:exited, _reason, :error}) when s in ["finished", "failed"],
    do: {:ok, %{vm | alive: false}, [:cleanup_failed]}

  # The box disconnects.
  def transition(%{state: "requested"} = vm, :box_disconnected),
    do: fail(vm, "lost", [:delete_runner])

  def transition(%{state: s} = vm, :box_disconnected) when s in ["starting", "booted", "idle"],
    do: {:ok, vm, [{:delete_runner_then, "lost"}]}

  def transition(_vm, :box_disconnected), do: :ignored

  def transition(vm, :box_revoked), do: {:ok, %{vm | state: "destroyed", alive: false}, []}

  # The join inventory (§10.6).
  def transition(%{state: s} = vm, :inventory_missing) when s in @pre_job,
    do: fail(vm, "lost", [:delete_runner])

  def transition(%{state: "busy"} = vm, :inventory_missing),
    do: {:ok, %{vm | state: "finished", alive: false}, [:arm_finished]}

  def transition(%{state: s} = vm, :inventory_missing) when s in ["finished", "failed"],
    do: {:ok, %{vm | state: "destroyed", alive: false}, []}

  def transition(%{state: s} = vm, :inventory_alive) when s in ["finished", "failed"],
    do: {:ok, %{vm | alive: true}, [{:stop, true}]}

  # Timeouts first delete the runner, when there is one.
  def transition(%{state: "requested"} = vm, {:timeout, "jit_timeout"}),
    do: fail(vm, "jit_timeout", [{:stop, true}])

  def transition(%{state: s} = vm, {:timeout, reason})
      when s in ["requested", "starting", "booted"],
      do: {:ok, vm, [{:delete_runner_then, reason}]}

  # Reaping (§8.5): delete the runner, and on 204/404 stop the VM.
  def transition(%{state: "idle"} = vm, {:reap, _why}),
    do: {:ok, vm, [{:delete_runner_then, "reaped"}]}

  def transition(%{state: "idle"} = vm, {:runner_deleted, :gone, "reaped"}),
    do: {:ok, %{vm | state: "finished", fail_reason: "reaped"}, [{:stop, false}, :arm_finished]}

  def transition(%{state: s} = vm, {:runner_deleted, :gone, reason}) when s in @pre_job,
    do: fail(vm, reason, [{:stop, true}])

  def transition(%{state: s} = vm, {:runner_deleted, :busy, _reason}) when s in @pre_job,
    do: {:ok, %{vm | state: "busy", fail_reason: nil}, [:fetch_job]}

  def transition(%{state: "finished"} = vm, {:finished_timer, :grace}),
    do: {:ok, vm, [{:stop, false}]}

  def transition(%{state: "finished"} = vm, {:finished_timer, :force}),
    do: {:ok, vm, [{:stop, true}]}

  def transition(%{state: "failed", alive: true} = vm, :failed_alive_tick),
    do: {:ok, vm, [{:stop, true}]}

  # The agent enforces the deadline (§10.7); this is the control plane's.
  def transition(%{state: "busy"} = vm, :deadline), do: {:ok, vm, [{:stop, true}]}

  def transition(_vm, _event), do: :ignored

  defp to(vm, state, effects \\ []), do: {:ok, %{vm | state: state}, effects}
  defp fail(vm, reason, effects), do: {:ok, %{vm | state: "failed", fail_reason: reason}, effects}

  @doc "Failures that count toward box quarantine (§8.6): before idle, the box's fault."
  def quarantine_failure?(reason),
    do: reason in ~w(boot_failed boot_timeout runner_timeout crashed start_error)

  @doc "States that hold a box's allocation: every one but destroyed."
  def allocated?(state), do: state != "destroyed"
end
