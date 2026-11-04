defmodule Crew.Scheduler.QueueTest do
  @moduledoc "The Queue page's view of a pass (§17.3): units in placement order, and each class."
  use ExUnit.Case, async: true

  import Crew.PlanFixtures

  alias Crew.Scheduler.Plan

  test "units in the order they'd be placed: priority, then alternating repos, then age" do
    repos = [repo("repo-a"), repo("repo-b"), repo("repo-c", priority: 5)]

    jobs = [
      job(1, repo_id: "repo-a"),
      job(2, repo_id: "repo-a"),
      job(3, repo_id: "repo-b"),
      job(4, repo_id: "repo-c")
    ]

    b = box("a", vcpus: 1024, memory_mib: 4_000_000, vm_area_mib: 100_000_000, max_vms: 2)
    queue = Plan.queue(snapshot(boxes: [b], repos: repos, jobs: jobs))

    assert Enum.map(queue.units, & &1.job_id) == ["job-4", "job-1", "job-3", "job-2"]

    assert [
             %{placed: true},
             %{placed: true},
             %{placed: false, wait_reason: wait},
             %{placed: false}
           ] = queue.units

    assert wait =~ "VM limit"
  end

  test "covered and blocked jobs, apart from the units" do
    vms = [vm(1, "box-a", state: "idle")]
    jobs = [job(1), job(2), job(3, arch: :x64, label_key: ["crew-m-x64"])]
    queue = Plan.queue(snapshot(vms: vms, jobs: jobs))

    assert queue.covered == ["job-1"]
    assert Enum.map(queue.units, & &1.job_id) == ["job-2"]
    assert [{"job-3", "no x64 box"}] = queue.blocked
  end

  test "per class: demand, supply and deficit, with stalls and backoff" do
    cs = %{{"repo-a", ["crew-m"]} => %{backoff_until: now() + 60_000, last_error: "boot_timeout"}}
    vms = [vm(1, "box-a", state: "starting")]
    queue = Plan.queue(snapshot(vms: vms, jobs: [job(1), job(2), job(3)], class_state: cs))

    assert %{
             demand: 3,
             supply: 1,
             deficit: 2,
             backoff: true,
             stalled: false,
             last_error: "boot_timeout"
           } =
             queue.classes[{"repo-a", ["crew-m"]}]
  end

  test "a class whose jobs are all blocked (stalled, say) still shows, with its blocked count" do
    cs = %{{"repo-a", ["crew-m"]} => %{stalled_until: now() + 60_000}}
    queue = Plan.queue(snapshot(jobs: [job(1), job(2)], class_state: cs))
    assert %{demand: 0, blocked: 2, stalled: true} = queue.classes[{"repo-a", ["crew-m"]}]
  end

  test "jobs held for the fork check show as blocked, though they're not demand" do
    queue = Plan.queue(snapshot(jobs: [job(1, blocked_reason: "checking fork status")]))
    assert queue.units == []
    assert [{"job-1", "checking fork status"}] = queue.blocked
    assert queue.classes == %{}
  end
end
