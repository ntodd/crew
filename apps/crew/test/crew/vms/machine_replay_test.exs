defmodule Crew.VMs.MachineReplayTest do
  @moduledoc """
  Replays the Quint model's calls of the transition table against
  `Crew.VMs.Machine.transition/2`.

  `models/vm_lifecycle.qnt` carries its own copy of the table and records
  every call its control plane makes: the VM it passed, the event, and
  what came back. `models/export_steps.exs` collects those from simulation
  traces into `test/fixtures/quint/vm_lifecycle_steps.json`. If the two
  tables drift apart, a step here fails.
  """
  use ExUnit.Case, async: true

  alias Crew.VMs.Machine

  @fixture Path.expand("../../fixtures/quint/vm_lifecycle_steps.json", __DIR__)
  @steps @fixture |> File.read!() |> JSON.decode!()

  @states ~w(requested starting booted idle busy finished failed destroyed)
  @events ~w(StartResult Booted RunnerListening JobStarted GuestJobStarted JobCompleted
             Exited BoxDisconnected InventoryMissing InventoryAlive Timeout Reap
             RunnerDeleted FinishedTimer FailedAliveTick Deadline)

  defp vm(%{"state" => s, "reason" => r, "jobId" => j, "alive" => a}),
    do: %{state: s, fail_reason: blank(r), job_id: blank(j), alive: a}

  defp blank(""), do: nil
  defp blank(value), do: value

  defp outcome("gone"), do: :gone
  defp outcome("busy"), do: :busy

  defp timer("grace"), do: :grace
  defp timer("force"), do: :force

  defp event(%{"tag" => tag, "value" => v}), do: event(tag, v)

  defp event("StartSent", _), do: :start_sent
  defp event("StartResult", ok), do: {:start_result, if(ok, do: :ok, else: :error)}
  defp event("Booted", _), do: :booted
  defp event("RunnerListening", _), do: :runner_listening
  defp event("JobStarted", job), do: {:job_started, job}
  defp event("GuestJobStarted", _), do: :guest_job_started
  defp event("JobCompleted", job), do: {:job_completed, job}

  defp event("Exited", %{"reason" => reason, "cleanupOk" => ok}),
    do: {:exited, reason, if(ok, do: :ok, else: :error)}

  defp event("BoxDisconnected", _), do: :box_disconnected
  defp event("InventoryMissing", _), do: :inventory_missing
  defp event("InventoryAlive", _), do: :inventory_alive
  defp event("Timeout", reason), do: {:timeout, reason}
  defp event("Reap", why), do: {:reap, why}

  defp event("RunnerDeleted", %{"outcome" => outcome, "reason" => reason}),
    do: {:runner_deleted, outcome(outcome), reason}

  defp event("FinishedTimer", kind), do: {:finished_timer, timer(kind)}
  defp event("FailedAliveTick", _), do: :failed_alive_tick
  defp event("Deadline", _), do: :deadline

  defp effect(%{"tag" => tag, "value" => v}), do: effect(tag, v)

  defp effect("RecordStartOp", _), do: :record_start_op
  defp effect("DeleteRunner", _), do: :delete_runner
  defp effect("DeleteRunnerThen", reason), do: {:delete_runner_then, reason}
  defp effect("Stop", force), do: {:stop, force}
  defp effect("FetchJob", _), do: :fetch_job
  defp effect("LinkJob", job), do: {:link_job, job}
  defp effect("CancelForceStop", _), do: :cancel_force_stop
  defp effect("ArmFinished", _), do: :arm_finished
  defp effect("Success", _), do: :success
  defp effect("CleanupFailed", _), do: :cleanup_failed

  defp describe(step),
    do: "#{inspect(vm(step["before"]))} + #{inspect(event(step["event"]))}"

  # One test per (state, event) cell the model walked, so a drift names
  # its cell.
  for {{state, tag}, steps} <- Enum.group_by(@steps, &{&1["before"]["state"], &1["event"]["tag"]}) do
    @cell steps
    test "#{state} + #{tag} (#{length(steps)} steps)" do
      for step <- @cell do
        result = Machine.transition(vm(step["before"]), event(step["event"]))

        if step["ignored"] do
          assert result == :ignored, "#{describe(step)}: expected ignored, got #{inspect(result)}"
        else
          expected = vm(step["after"])
          effects = step["effects"] |> Enum.map(&effect/1) |> Enum.sort()

          assert {:ok, ^expected, got} = result, describe(step)
          assert Enum.sort(got) == effects, "#{describe(step)}: effects #{inspect(got)}"
        end
      end
    end
  end

  test "the traces reach every state and feed every event" do
    before = MapSet.new(@steps, & &1["before"]["state"])
    after_ = MapSet.new(@steps, & &1["after"]["state"])
    events = MapSet.new(@steps, & &1["event"]["tag"])

    assert MapSet.new(@states) == MapSet.union(before, after_)
    assert MapSet.new(@events) |> MapSet.subset?(events)
  end
end
