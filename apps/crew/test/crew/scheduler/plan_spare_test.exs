defmodule Crew.Scheduler.PlanSpareTest do
  @moduledoc "Spare jobs (§7.2): placed after regular ones, within each box's spare share."
  use ExUnit.Case, async: true

  import Crew.PlanFixtures

  alias Crew.Scheduler.Plan

  @s size("s", 2, 4096, 40)
  @m size("m", 4, 8192, 60)
  @xl size("xl", 16, 32_768, 150)
  @sizes [@s, @m, @xl]

  @rule1 "waiting for spare room: spare jobs are at their share of every box that fits"
  @rule2 "waiting for spare room: regular jobs are waiting for the boxes that fit"
  @never "no box's spare share could ever hold this size"

  defp spare_job(n, attrs \\ []) do
    size = Keyword.get(attrs, :size, "m")

    job(
      n,
      [spare: true, size_id: "size-" <> size, label_key: ["crew-#{size}-spare"]] ++ attrs
    )
  end

  defp regular_job(n, attrs \\ []) do
    size = Keyword.get(attrs, :size, "m")
    job(n, [spare: false, size_id: "size-" <> size, label_key: ["crew-#{size}"]] ++ attrs)
  end

  defp big_box(name, attrs \\ []),
    do: box(name, [vcpus: 1024, memory_mib: 4_000_000, vm_area_mib: 100_000_000] ++ attrs)

  defp linux_a(attrs \\ []) do
    box(
      "linux-a",
      [
        vcpus: 24,
        memory_mib: 65_536,
        vm_area_mib: 786_432,
        guest_arch: "x64",
        vmm_overhead_mib: 64
      ] ++ attrs
    )
  end

  defp plan(attrs), do: Plan.plan(snapshot([sizes: @sizes] ++ attrs))

  defp reason(actions, id) do
    [r] = for {:reasons, ^id, blocked, wait} <- actions, do: {blocked, wait}
    r
  end

  describe "order (§8.4)" do
    test "in one pass, every regular unit is placed before any spare unit" do
      repos = [repo("repo-a"), repo("repo-b", priority: 10)]

      jobs =
        for(n <- 1..3, do: spare_job(n, repo_id: "repo-b", queued_at: now() - 100_000 + n)) ++
          for(n <- 4..6, do: regular_job(n, queued_at: now() + n))

      placed = placements(plan(boxes: [big_box("a")], repos: repos, jobs: jobs))
      assert Enum.map(placed, & &1.spare) == [false, false, false, true, true, true]
      assert Enum.map(placed, & &1.job_id) == ~w(job-4 job-5 job-6 job-1 job-2 job-3)
    end

    test "a repo's spare VMs don't put its regular jobs behind another repo's" do
      repos = [repo("repo-a"), repo("repo-b")]
      spare_vms = for i <- 1..10, do: vm(i, "box-a", spare: true, state: "busy", job_id: "x#{i}")

      jobs =
        for(n <- 1..5, do: regular_job(n, repo_id: "repo-a")) ++
          for(n <- 11..15, do: regular_job(n, repo_id: "repo-b", queued_at: now() + n))

      placed = placements(plan(boxes: [big_box("a")], repos: repos, vms: spare_vms, jobs: jobs))
      assert Enum.map(placed, & &1.repo_id) == List.flatten(List.duplicate(~w(repo-a repo-b), 5))
    end

    test "spare units alternate repos by their spare VMs" do
      repos = [repo("repo-a"), repo("repo-b")]
      regular_vms = for i <- 1..10, do: vm(i, "box-a", state: "busy", job_id: "x#{i}")

      jobs =
        for(n <- 1..3, do: spare_job(n, repo_id: "repo-a")) ++
          for(n <- 11..13, do: spare_job(n, repo_id: "repo-b", queued_at: now() + n))

      placed =
        placements(
          plan(boxes: [big_box("a", spare_pct: 100)], repos: repos, vms: regular_vms, jobs: jobs)
        )

      assert Enum.map(placed, & &1.repo_id) == List.flatten(List.duplicate(~w(repo-a repo-b), 3))
    end
  end

  describe "the spare share (§8.3 rule 1)" do
    test "the worked example: linux-a at 50% holds 3 spare m VMs" do
      jobs = for n <- 1..10, do: spare_job(n)
      actions = plan(boxes: [linux_a()], jobs: jobs)
      assert length(placements(actions)) == 3
      assert reason(actions, "job-4") == {nil, @rule1}

      # Regular, the same box holds 7.
      assert length(placements(plan(boxes: [linux_a()], jobs: for(n <- 1..10, do: job(n))))) ==
               7
    end

    test "spare_pct 0 keeps spare jobs off, 100 lets them fill the box, unset is 50" do
      jobs = for n <- 1..10, do: spare_job(n)

      actions = plan(boxes: [linux_a(spare_pct: 0)], jobs: jobs)
      assert placements(actions) == []
      assert reason(actions, "job-1") == {@never, nil}

      assert length(placements(plan(boxes: [linux_a(spare_pct: 100)], jobs: jobs))) == 7
      assert length(placements(plan(boxes: [linux_a(spare_pct: nil)], jobs: jobs))) == 3
      assert length(placements(plan(boxes: [linux_a(spare_pct: 50)], jobs: jobs))) == 3
    end

    test "the vCPU share can bind before the memory share" do
      # (9 - 1) × 1.5 = 12 vCPUs, half of it 6: one 4-vCPU VM.
      b = box("a", vcpus: 9, memory_mib: 1_000_000)
      assert length(placements(plan(boxes: [b], jobs: for(n <- 1..4, do: spare_job(n))))) == 1
    end

    test "the max_vms share is rounded down" do
      jobs = for n <- 1..4, do: spare_job(n)
      assert length(placements(plan(boxes: [big_box("a", max_vms: 4)], jobs: jobs))) == 2
      assert length(placements(plan(boxes: [big_box("a", max_vms: 5)], jobs: jobs))) == 2

      actions = plan(boxes: [big_box("a", max_vms: 1)], jobs: jobs)
      assert placements(actions) == []
      assert reason(actions, "job-1") == {@never, nil}
    end

    test "existing spare VMs count, in any state but destroyed; regular ones don't" do
      vms = [
        vm(1, "box-linux-a", spare: true, state: "busy", job_id: "x", vmm_overhead_mib: 263),
        vm(2, "box-linux-a", spare: true, state: "finished", job_id: "y", vmm_overhead_mib: 263),
        vm(3, "box-linux-a", spare: false, state: "busy", job_id: "z", vmm_overhead_mib: 263)
      ]

      placed =
        placements(plan(boxes: [linux_a()], vms: vms, jobs: for(n <- 1..5, do: spare_job(n))))

      assert length(placed) == 1
    end

    test "a box already over its share gets no spare placement" do
      vms = for i <- 1..4, do: vm(i, "box-linux-a", spare: true, state: "busy", job_id: "x#{i}")
      actions = plan(boxes: [linux_a()], vms: vms, jobs: [spare_job(1, size: "s")])
      assert placements(actions) == []
      assert reason(actions, "job-1") == {nil, @rule1}
    end

    test "regular units ignore the share" do
      vms = for i <- 1..3, do: vm(i, "box-linux-a", spare: true, state: "busy", job_id: "x#{i}")
      placed = placements(plan(boxes: [linux_a()], vms: vms, jobs: for(n <- 1..10, do: job(n))))
      assert length(placed) == 4
    end

    test "a spare VM that took a regular job keeps counting toward the share" do
      # Two spare VMs that took a regular alias job across classes.
      vms =
        for i <- 1..2 do
          vm(i, "box-linux-a",
            spare: true,
            state: "busy",
            job_id: "alias-#{i}",
            label_key: ["crew-m-spare", "self-hosted"],
            vmm_overhead_mib: 263
          )
        end

      jobs = for n <- 1..3, do: spare_job(n)
      assert length(placements(plan(boxes: [linux_a()], vms: vms, jobs: jobs))) == 1
    end
  end

  describe "no regular unit waiting for the box (§8.3 rule 2)" do
    # a: arm64, holds a busy xl, so a regular xl doesn't fit now but could.
    defp rule2_boxes do
      [
        box("a", vcpus: 32, memory_mib: 65_536),
        box("b", guest_arch: "x64"),
        box("c"),
        box("d", vcpus: 8, memory_mib: 16_384)
      ]
    end

    defp busy_xl(n, box_id, attrs \\ []) do
      vm(
        n,
        box_id,
        [
          repo_id: "repo-c",
          state: "busy",
          job_id: "x#{n}",
          vcpus: 16,
          memory_mib: 32_768,
          disk_gib: 150,
          label_key: ["crew-xl"]
        ] ++ attrs
      )
    end

    defp repos(xl_boxes, attrs \\ []) do
      [
        repo("repo-a", [allowed_boxes: xl_boxes] ++ attrs),
        repo("repo-b"),
        repo("repo-c")
      ]
    end

    test "a waiting regular xl keeps spare units off the boxes it could use, and only those" do
      jobs =
        [regular_job(1, size: "xl", arch: :arm64)] ++
          for n <- 2..13, do: spare_job(n, size: "s", repo_id: "repo-b")

      actions =
        plan(
          boxes: rule2_boxes(),
          repos: repos(["box-a", "box-b", "box-d"]),
          vms: [busy_xl(1, "box-a")],
          jobs: jobs
        )

      assert {nil, "no box with 32 GiB free" <> _} = reason(actions, "job-1")
      by_box = actions |> placements() |> Enum.frequencies_by(& &1.box_id)

      # b is the other arch, c is outside its allowed boxes, d could never hold an xl.
      refute Map.has_key?(by_box, "box-a")
      assert by_box == %{"box-b" => 5, "box-c" => 5, "box-d" => 1}
      assert reason(actions, "job-13") == {nil, @rule2}
    end

    test "without the waiting regular unit, a takes spare units too" do
      jobs = for n <- 2..13, do: spare_job(n, size: "s", repo_id: "repo-b")

      by_box =
        plan(boxes: rule2_boxes(), repos: repos(nil), vms: [busy_xl(1, "box-a")], jobs: jobs)
        |> placements()
        |> Enum.frequencies_by(& &1.box_id)

      assert by_box["box-a"] >= 1
    end

    test "a regular unit held by max_concurrent keeps nothing free" do
      jobs = [
        regular_job(1, size: "xl", arch: :arm64),
        spare_job(2, size: "s", repo_id: "repo-b")
      ]

      held = vm(9, "box-a", repo_id: "repo-a", state: "busy", job_id: "y")

      actions =
        plan(
          boxes: [box("a", vcpus: 32, memory_mib: 65_536)],
          repos: repos(["box-a"], max_concurrent: 1),
          vms: [busy_xl(1, "box-a"), held],
          jobs: jobs
        )

      assert reason(actions, "job-1") == {"repo at max_concurrent", nil}
      assert [%{job_id: "job-2", box_id: "box-a"}] = placements(actions)
    end

    test "a regular unit in class backoff keeps nothing free" do
      jobs = [
        regular_job(1, size: "xl", arch: :arm64),
        spare_job(2, size: "s", repo_id: "repo-b")
      ]

      cs = %{{"repo-a", ["crew-xl"]} => %{backoff_until: now() + 10_000, last_error: "boom"}}

      actions =
        plan(
          boxes: [box("a", vcpus: 32, memory_mib: 65_536)],
          repos: repos(["box-a"]),
          vms: [busy_xl(1, "box-a")],
          jobs: jobs,
          class_state: cs
        )

      assert {nil, "Crew can't start runners" <> _} = reason(actions, "job-1")
      assert [%{job_id: "job-2", box_id: "box-a"}] = placements(actions)
    end
  end

  describe "could ever hold (§8.2)" do
    test "a spare job no box's share could ever hold is blocked, and a regular one isn't" do
      actions = plan(jobs: [spare_job(1, size: "xl"), regular_job(2, size: "xl")])
      assert reason(actions, "job-1") == {@never, nil}
      assert [%{job_id: "job-2"}] = placements(actions)
    end

    test "the share has to pass the driver's per-VM limits too" do
      b = box("a", spare_pct: 100, max_vcpus_per_vm: 2)
      assert reason(plan(boxes: [b], jobs: [spare_job(1)]), "job-1") == {@never, nil}
    end
  end

  describe "max_concurrent (§7.4)" do
    test "regular units count the repo's regular VMs; spare units count all of them" do
      repos = [repo("repo-a", max_concurrent: 2)]

      vms = [
        vm(1, "box-a", state: "busy", job_id: "x"),
        vm(2, "box-a", spare: true, state: "busy", job_id: "y")
      ]

      actions =
        plan(boxes: [big_box("a")], repos: repos, vms: vms, jobs: [regular_job(1), spare_job(2)])

      assert [%{job_id: "job-1"}] = placements(actions)
      assert reason(actions, "job-2") == {"repo at max_concurrent", nil}
    end

    test "a repo's spare VMs never hold back its regular jobs" do
      repos = [repo("repo-a", max_concurrent: 2)]
      vms = for i <- 1..2, do: vm(i, "box-a", spare: true, state: "busy", job_id: "x#{i}")

      actions =
        plan(
          boxes: [big_box("a")],
          repos: repos,
          vms: vms,
          jobs: [regular_job(1), regular_job(2)]
        )

      assert length(placements(actions)) == 2
    end
  end

  describe "wait reasons (§8.2)" do
    # a: a regular xl from repo-a waits for it. b: outside repo-a's boxes,
    # its spare share (10%) taken by one spare s.
    defp share_full(name),
      do:
        vm(50, "box-#{name}",
          spare: true,
          state: "busy",
          job_id: "s50",
          vcpus: 2,
          memory_mib: 4096,
          disk_gib: 40
        )

    test "one box fails rule 2 only, another rule 1 only: the rule 2 reason" do
      actions =
        plan(
          boxes: [box("a", vcpus: 32, memory_mib: 65_536), box("b", spare_pct: 10)],
          repos: repos(["box-a"]),
          vms: [busy_xl(1, "box-a"), share_full("b")],
          jobs: [
            regular_job(1, size: "xl", arch: :arm64),
            spare_job(2, size: "s", repo_id: "repo-b")
          ]
        )

      assert placements(actions) == []
      assert reason(actions, "job-2") == {nil, @rule2}
    end

    test "a box failing both: the rule 2 reason" do
      actions =
        plan(
          boxes: [box("a", vcpus: 32, memory_mib: 65_536, spare_pct: 10)],
          repos: repos(["box-a"]),
          vms: [busy_xl(1, "box-a"), share_full("a")],
          jobs: [
            regular_job(1, size: "xl", arch: :arm64),
            spare_job(2, size: "s", repo_id: "repo-b")
          ]
        )

      assert reason(actions, "job-2") == {nil, @rule2}
    end

    test "only rule 1: the share reason" do
      actions =
        plan(
          boxes: [box("b", spare_pct: 10)],
          vms: [share_full("b")],
          jobs: [spare_job(2, size: "s")]
        )

      assert reason(actions, "job-2") == {nil, @rule1}
    end

    test "no ordinary fits: the reason a regular job would get" do
      vms = for i <- 1..7, do: vm(i, "box-a", state: "busy", job_id: "x#{i}")
      actions = plan(vms: vms, jobs: [spare_job(1, size: "s"), regular_job(2, size: "s")])
      {nil, regular} = reason(actions, "job-2")
      assert regular =~ "no box with 4 GiB free"
      assert reason(actions, "job-1") == {nil, regular}
    end
  end

  describe "coverage inside a class (§8.1)" do
    test "the rename hand-over: regular VMs cover spare jobs, and don't count toward the share" do
      key = ["crew-m-spare"]
      vms = for i <- 1..3, do: vm(i, "box-linux-a", label_key: key, state: "idle", idle_at: now())
      jobs = for n <- 1..6, do: spare_job(n)

      actions = plan(boxes: [linux_a()], vms: vms, jobs: jobs)
      placed = placements(actions)
      assert Enum.map(placed, & &1.job_id) == ~w(job-4 job-5 job-6)
      assert Enum.all?(placed, & &1.spare)
      for n <- 1..3, do: assert(reason(actions, "job-#{n}") == {nil, nil})
    end

    test "mid-reclassify, the class's supply covers its regular jobs first" do
      key = ["crew-m-spare"]
      vms = [vm(1, "box-a", label_key: key, state: "idle", idle_at: now())]

      jobs = [
        spare_job(1, queued_at: now() - 10_000),
        job(2, label_key: key, spare: false, queued_at: now())
      ]

      actions = plan(vms: vms, jobs: jobs)
      assert [%{job_id: "job-1", spare: true}] = placements(actions)
      assert reason(actions, "job-2") == {nil, nil}
    end
  end

  describe "the VM lifecycle doesn't look at the tier (§8.5)" do
    test "spare VMs are reaped for excess and idle_max like regular ones" do
      key = ["crew-m-spare"]
      class = {"repo-a", key}

      vms = [
        vm(1, "box-a", spare: true, label_key: key, idle_at: now() - 600_001),
        vm(2, "box-a", spare: true, label_key: key, idle_at: now() - 1000)
      ]

      actions = plan(vms: vms, class_state: %{class => %{excess_since: now() - 31_000}})
      assert {:reap, "vm-1", :idle_max} in actions
      assert {:reap, "vm-2", :excess} in actions
    end
  end
end
