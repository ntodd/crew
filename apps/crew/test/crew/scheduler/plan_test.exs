defmodule Crew.Scheduler.PlanTest do
  use ExUnit.Case, async: true

  import Crew.PlanFixtures

  alias Crew.Scheduler.Plan

  describe "the worked example (§8.3)" do
    test "30 crew-m jobs on boxes that hold 7, 3 and 6: 16 run, 14 wait" do
      boxes = [
        box("linux-a",
          vcpus: 24,
          memory_mib: 65_536,
          vm_area_mib: 786_432,
          guest_arch: "x64",
          vmm_overhead_mib: 64
        ),
        box("m3max", vcpus: 14, memory_mib: 36_864, vm_area_mib: 204_800, vmm_overhead_mib: 64),
        box("m1ultra",
          vcpus: 18,
          memory_mib: 110_592,
          vm_area_mib: 409_600,
          vmm_overhead_mib: 128
        )
      ]

      jobs = for n <- 1..30, do: job(n)
      actions = Plan.plan(snapshot(boxes: boxes, jobs: jobs))
      placed = placements(actions)

      assert length(placed) == 16
      by_box = Enum.frequencies_by(placed, & &1.box_id)
      assert by_box == %{"box-linux-a" => 7, "box-m3max" => 3, "box-m1ultra" => 6}

      # The 14 that wait say why.
      waiting = for {:reasons, id, nil, wait} <- actions, wait != nil, do: id
      assert length(waiting) == 14
    end

    test "the allocatable figures behind it" do
      linux = box("linux-a", vcpus: 24, memory_mib: 65_536, vm_area_mib: 786_432)
      assert Plan.allocatable_vcpus(linux) == 34.5
      assert Plan.allocatable_memory_mib(linux) == 60_212
      m3 = box("m3max", vcpus: 14, memory_mib: 36_864)
      assert Plan.allocatable_memory_mib(m3) == 32_973
    end
  end

  describe "fitting a size (§8.3)" do
    test "memory, with VMM overhead, is never overcommitted" do
      b = box("a", vcpus: 64, memory_mib: 20_000, reserve_memory_mib: 0)
      # 2 × (8192 + 64) = 16512 fits; a third doesn't.
      actions = Plan.plan(snapshot(boxes: [b], jobs: for(n <- 1..3, do: job(n))))
      assert length(placements(actions)) == 2
    end

    test "vCPUs are overcommitted 1.5×" do
      b = box("a", vcpus: 9, memory_mib: 1_000_000)
      # (9 - 1) × 1.5 = 12 → three 4-vCPU VMs.
      assert length(placements(Plan.plan(snapshot(boxes: [b], jobs: for(n <- 1..5, do: job(n)))))) ==
               3
    end

    test "per-VM maxima" do
      b = box("a", max_vcpus_per_vm: 2)
      actions = Plan.plan(snapshot(boxes: [b], jobs: [job(1)]))
      assert placements(actions) == []
      assert {:reasons, "job-1", "no box could ever hold this size", nil} in actions
    end

    test "max_vms" do
      b = box("a", vcpus: 64, memory_mib: 1_000_000, max_vms: 2)

      assert length(placements(Plan.plan(snapshot(boxes: [b], jobs: for(n <- 1..4, do: job(n)))))) ==
               2
    end

    test "disk: projected free space keeps 15% of the clone area" do
      b =
        box("a",
          vcpus: 64,
          memory_mib: 1_000_000,
          vm_area_mib: 102_400,
          vm_area_free_mib: 102_400
        )

      # each placement projects 30,720 MiB: 102400 - 30720k ≥ 15360 → k ≤ 2.83 → 2
      assert length(placements(Plan.plan(snapshot(boxes: [b], jobs: for(n <- 1..4, do: job(n)))))) ==
               2
    end

    test "VMs not yet destroyed count toward the box's allocation, in any state" do
      b = box("a", vcpus: 9, memory_mib: 1_000_000)
      vms = [vm(1, b.id, state: "busy", job_id: "x"), vm(2, b.id, state: "finished", job_id: "y")]

      assert length(
               placements(
                 Plan.plan(snapshot(boxes: [b], vms: vms, jobs: for(n <- 1..3, do: job(n))))
               )
             ) == 1
    end
  end

  describe "eligible boxes" do
    test "offline, draining, quarantined, needing approval, or without a verified firewall: not eligible" do
      future = now() + 60_000

      states = [
        [online: false],
        [draining: true],
        [quarantined_until: future],
        [needs_approval: true],
        [firewall_ok: false]
      ]

      for attrs <- states do
        actions = Plan.plan(snapshot(boxes: [box("a", attrs)], jobs: [job(1)]))
        assert placements(actions) == [], inspect(attrs)
        assert [{:reasons, "job-1", reason, nil}] = for(r = {:reasons, _, _, _} <- actions, do: r)
        assert reason =~ "the only boxes that fit are"
      end
    end

    test "an expired quarantine is over" do
      actions =
        Plan.plan(snapshot(boxes: [box("a", quarantined_until: now() - 1)], jobs: [job(1)]))

      assert length(placements(actions)) == 1
    end

    test "arch" do
      actions =
        Plan.plan(snapshot(boxes: [box("a", guest_arch: "arm64")], jobs: [job(1, arch: :x64)]))

      assert {:reasons, "job-1", "no x64 box", nil} in actions

      assert [%{box_id: "box-a"}] =
               placements(Plan.plan(snapshot(boxes: [box("a")], jobs: [job(1, arch: :arm64)])))
    end

    test "no boxes enrolled" do
      actions = Plan.plan(snapshot(boxes: [], jobs: [job(1)]))
      assert {:reasons, "job-1", "no boxes enrolled", nil} in actions
    end

    test "the repo's allowed boxes" do
      repos = [%{id: "repo-a", priority: 0, max_concurrent: nil, allowed_boxes: ["box-b"]}]
      actions = Plan.plan(snapshot(boxes: [box("a"), box("b")], repos: repos, jobs: [job(1)]))
      assert [%{box_id: "box-b"}] = placements(actions)
    end

    test "max_concurrent caps the repo's active VMs" do
      repos = [%{id: "repo-a", priority: 0, max_concurrent: 2, allowed_boxes: nil}]
      vms = [vm(1, "box-a", state: "busy", job_id: "x")]
      actions = Plan.plan(snapshot(repos: repos, vms: vms, jobs: for(n <- 1..3, do: job(n))))
      assert length(placements(actions)) == 1
      assert Enum.any?(actions, &match?({:reasons, _, "repo at max_concurrent", nil}, &1))
    end

    test "a class in backoff isn't placed, and says why" do
      cs = %{
        {"repo-a", ["crew-m"]} => %{
          backoff_until: now() + 10_000,
          last_error: "boot_timeout",
          stalled_until: nil
        }
      }

      actions = Plan.plan(snapshot(jobs: [job(1)], class_state: cs))
      assert placements(actions) == []

      assert {:reasons, "job-1", nil, "Crew can't start runners for this class: boot_timeout"} in actions
    end

    test "a stalled class is blocked" do
      cs = %{{"repo-a", ["crew-m"]} => %{stalled_until: now() + 60_000, backoff_until: nil}}
      actions = Plan.plan(snapshot(jobs: [job(1)], class_state: cs))
      assert [{:reasons, "job-1", reason, nil}] = for(r = {:reasons, _, _, _} <- actions, do: r)
      assert reason =~ "GitHub isn't assigning jobs to runners labelled [crew-m]"
    end
  end

  describe "images (§8.3)" do
    @images %{
      "arm64" => %{
        default: "img-4",
        recent_defaults: ["img-4", "img-3"],
        order: ["img-4", "img-3", "img-2", "img-1"]
      }
    }

    defp removed(actions), do: for({:remove_image, b, i} <- actions, do: {b, i})

    test "a box keeps the default, the usable one and the newest other; the rest go (§13.1)" do
      bi = %{
        {"box-a", "img-4"} => "downloading",
        {"box-a", "img-3"} => "ready",
        {"box-a", "img-2"} => "ready",
        {"box-a", "img-1"} => "ready"
      }

      actions = Plan.plan(snapshot(images: @images, box_images: bi))
      assert removed(actions) == [{"box-a", "img-1"}]

      # Once the default is ready, it's also the usable one.
      actions =
        Plan.plan(snapshot(images: @images, box_images: %{bi | {"box-a", "img-4"} => "ready"}))

      assert Enum.sort(removed(actions)) == [{"box-a", "img-1"}, {"box-a", "img-2"}]
    end

    test "an image a VM on the box started from stays, and an offline box is left alone" do
      bi = for i <- ~w(img-1 img-2 img-3 img-4), into: %{}, do: {{"box-a", i}, "ready"}
      vms = [vm(1, "box-a", image_id: "img-1")]

      assert removed(Plan.plan(snapshot(images: @images, box_images: bi, vms: vms))) == [
               {"box-a", "img-2"}
             ]

      offline = box("a", online: false)
      assert removed(Plan.plan(snapshot(boxes: [offline], images: @images, box_images: bi))) == []
    end

    test "a box without a usable image isn't eligible, and is sent image.prepare" do
      actions = Plan.plan(snapshot(jobs: [job(1)], box_images: %{}))
      assert placements(actions) == []
      assert {:prepare_image, "box-a", "img-1"} in actions
    end

    test "a box keeps using a recent default while the new one prepares" do
      images = %{"arm64" => %{default: "img-2", recent_defaults: ["img-2", "img-1"]}}
      bi = %{{"box-a", "img-1"} => "ready", {"box-a", "img-2"} => "downloading"}
      actions = Plan.plan(snapshot(jobs: [job(1)], images: images, box_images: bi))
      assert [%{image_id: "img-1"}] = placements(actions)
      refute Enum.any?(actions, &match?({:prepare_image, _, _}, &1))
    end

    test "the default image wins the ranking" do
      images = %{"arm64" => %{default: "img-2", recent_defaults: ["img-2", "img-1"]}}

      bi = %{
        {"box-a", "img-1"} => "ready",
        {"box-b", "img-2"} => "ready",
        {"box-a", "img-2"} => "downloading"
      }

      actions =
        Plan.plan(
          snapshot(
            boxes: [box("a"), box("b", memory_mib: 32_768)],
            jobs: [job(1)],
            images: images,
            box_images: bi
          )
        )

      assert [%{box_id: "box-b", image_id: "img-2"}] = placements(actions)
    end
  end

  describe "ranking" do
    test "spreads by memory allocation" do
      actions = Plan.plan(snapshot(boxes: [box("a"), box("b")], jobs: for(n <- 1..4, do: job(n))))

      assert Enum.frequencies_by(placements(actions), & &1.box_id) == %{
               "box-a" => 2,
               "box-b" => 2
             }
    end

    test "prefers the box that last ran the repo, then the name" do
      boxes = [box("a"), box("b", last_repo_ran_at: %{"repo-a" => now() - 1000})]
      assert [%{box_id: "box-b"}] = placements(Plan.plan(snapshot(boxes: boxes, jobs: [job(1)])))

      assert [%{box_id: "box-a"}] =
               placements(Plan.plan(snapshot(boxes: [box("b"), box("a")], jobs: [job(1)])))
    end
  end

  describe "demand and supply (§8.1)" do
    test "idle and booting VMs of the class cover queued jobs" do
      vms = [vm(1, "box-a", state: "idle"), vm(2, "box-a", state: "starting")]
      actions = Plan.plan(snapshot(vms: vms, jobs: for(n <- 1..3, do: job(n))))
      assert length(placements(actions)) == 1
    end

    test "a VM with a job doesn't count as supply" do
      vms = [vm(1, "box-a", state: "busy", job_id: "x")]
      assert length(placements(Plan.plan(snapshot(vms: vms, jobs: [job(1)])))) == 1
    end

    test "an offline box's VMs leave supply" do
      boxes = [box("a", online: false), box("b")]
      vms = [vm(1, "box-a", state: "idle")]

      assert [%{box_id: "box-b"}] =
               placements(Plan.plan(snapshot(boxes: boxes, vms: vms, jobs: [job(1)])))
    end

    test "blocked jobs aren't demand" do
      actions = Plan.plan(snapshot(jobs: [job(1, blocked_reason: "checking fork status")]))
      assert placements(actions) == []
    end

    test "classes are per repo and label key" do
      vms = [vm(1, "box-a", state: "idle", label_key: ["crew-l"])]
      assert length(placements(Plan.plan(snapshot(vms: vms, jobs: [job(1)])))) == 1
    end
  end

  describe "ordering and fairness (§8.4)" do
    test "two waiting repos alternate" do
      repos = [repo("repo-a"), repo("repo-b")]

      jobs =
        for(n <- 1..10, do: job(n, repo_id: "repo-a")) ++
          for(n <- 11..20, do: job(n, repo_id: "repo-b", queued_at: now()))

      b = box("a", vcpus: 64, memory_mib: 1_000_000, max_vms: 6)
      placed = placements(Plan.plan(snapshot(boxes: [b], repos: repos, jobs: jobs)))
      assert Enum.frequencies_by(placed, & &1.repo_id) == %{"repo-a" => 3, "repo-b" => 3}
    end

    test "higher priority first" do
      repos = [repo("repo-a"), repo("repo-b", priority: 5)]
      jobs = [job(1, repo_id: "repo-a"), job(2, repo_id: "repo-b", queued_at: now())]
      b = box("a", vcpus: 64, memory_mib: 1_000_000, max_vms: 1)

      assert [%{repo_id: "repo-b"}] =
               placements(Plan.plan(snapshot(boxes: [b], repos: repos, jobs: jobs)))
    end

    test "oldest first, then lowest GitHub id" do
      b = box("a", vcpus: 64, memory_mib: 1_000_000, max_vms: 1)
      jobs = [job(2, queued_at: now()), job(1, queued_at: now())]
      assert [%{job_id: "job-1"}] = placements(Plan.plan(snapshot(boxes: [b], jobs: jobs)))
    end
  end

  describe "reaping (§8.5)" do
    test "excess idle VMs are reaped once it has lasted idle_grace, newest first" do
      vms = [
        vm(1, "box-a", idle_at: now() - 50_000),
        vm(2, "box-a", idle_at: now() - 40_000),
        vm(3, "box-a", state: "booted")
      ]

      class = {"repo-a", ["crew-m"]}
      actions = Plan.plan(snapshot(vms: vms, jobs: [job(1)]))
      assert {:excess_since, class, now()} in actions
      refute Enum.any?(actions, &match?({:reap, _, _}, &1))

      cs = %{class => %{excess_since: now() - 31_000}}
      actions = Plan.plan(snapshot(vms: vms, jobs: [job(1)], class_state: cs))
      # supply 3, demand 1: excess 2, but only the idle ones go, newest first.
      assert for({:reap, id, :excess} <- actions, do: id) == ["vm-2", "vm-1"]
    end

    test "no excess clears the clock" do
      class = {"repo-a", ["crew-m"]}
      cs = %{class => %{excess_since: now() - 31_000}}

      actions =
        Plan.plan(
          snapshot(vms: [vm(1, "box-a", idle_at: now())], jobs: [job(1)], class_state: cs)
        )

      assert {:excess_since, class, nil} in actions
    end

    test "a VM idle for CREW_IDLE_MAX is reaped whatever the demand" do
      vms = [vm(1, "box-a", idle_at: now() - 600_001)]
      actions = Plan.plan(snapshot(vms: vms, jobs: [job(1), job(2)]))
      assert {:reap, "vm-1", :idle_max} in actions
    end

    test "a draining box's idle VMs are reaped, and their supply placed elsewhere" do
      boxes = [box("a", draining: true), box("b")]
      vms = [vm(1, "box-a", idle_at: now())]
      actions = Plan.plan(snapshot(boxes: boxes, vms: vms, jobs: [job(1)]))
      assert {:reap, "vm-1", :draining} in actions
      assert [%{box_id: "box-b"}] = placements(actions)
    end
  end

  test "it's pure: the same snapshot gives the same actions" do
    snap = snapshot(boxes: [box("a"), box("b")], jobs: for(n <- 1..8, do: job(n)))
    assert Plan.plan(snap) == Plan.plan(snap)
  end
end
