defmodule Crew.Scheduler.PlanPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Crew.PlanFixtures

  alias Crew.Scheduler.Plan

  @sizes [size("s", 2, 4096, 40), size("m", 4, 8192, 60), size("l", 8, 16_384, 100)]

  defp gen_box do
    gen all(
          n <- integer(1..1000),
          vcpus <- integer(2..64),
          mem_gib <- integer(4..256),
          area_gib <- integer(100..2000),
          arch <- member_of(["arm64", "x64"]),
          online <- frequency([{4, constant(true)}, {1, constant(false)}]),
          max_vms <- one_of([constant(nil), integer(1..20)]),
          overhead <- member_of([64, 128])
        ) do
      box("b#{n}",
        vcpus: vcpus,
        memory_mib: mem_gib * 1024,
        vm_area_mib: area_gib * 1024,
        guest_arch: arch,
        online: online,
        max_vms: max_vms,
        vmm_overhead_mib: overhead
      )
    end
  end

  defp gen_snapshot do
    gen all(
          boxes <- uniq_list_of(gen_box(), uniq_fun: & &1.id, min_length: 1, max_length: 5),
          job_specs <-
            list_of(
              tuple(
                {member_of(["repo-a", "repo-b", "repo-c"]), member_of(@sizes),
                 member_of([:any, :arm64, :x64])}
              ),
              max_length: 60
            ),
          vm_specs <-
            list_of(
              tuple(
                {member_of(boxes), member_of(@sizes),
                 member_of(~w(requested starting booted idle busy finished failed))}
              ),
              max_length: 30
            )
        ) do
      jobs =
        job_specs
        |> Enum.with_index(1)
        |> Enum.map(fn {{repo, size, arch}, n} ->
          job(n, repo_id: repo, size_id: size.id, arch: arch, label_key: ["crew-#{size.name}"])
        end)

      vms =
        vm_specs
        |> Enum.with_index(1)
        |> Enum.map(fn {{box, size, state}, n} ->
          vm(n, box.id,
            state: state,
            vcpus: size.vcpus,
            memory_mib: size.memory_mib,
            disk_gib: size.disk_gib,
            vmm_overhead_mib: box.caps.vmm_overhead_mib,
            job_id: if(state in ~w(busy finished), do: "j#{n}"),
            label_key: ["crew-#{size.name}"],
            idle_at: if(state == "idle", do: now() - 1000)
          )
        end)

      repos =
        for r <- ["repo-a", "repo-b", "repo-c"],
            do: %{id: r, priority: 0, max_concurrent: nil, allowed_boxes: nil}

      snapshot(boxes: boxes, sizes: @sizes, jobs: jobs, vms: vms, repos: repos)
    end
  end

  defp allocation(snap, box, placements) do
    sizes = snap.sizes
    placed = for p <- placements, p.box_id == box.id, do: Map.fetch!(sizes, p.size_id)
    existing = for vm <- snap.vms, vm.box_id == box.id, do: vm

    mem =
      Enum.reduce(existing, 0, &(&1.memory_mib + &1.vmm_overhead_mib + &2)) +
        Enum.reduce(placed, 0, &(&1.memory_mib + box.caps.vmm_overhead_mib + &2))

    vcpus = Enum.reduce(existing, 0, &(&1.vcpus + &2)) + Enum.reduce(placed, 0, &(&1.vcpus + &2))
    {mem, vcpus, length(existing) + length(placed), placed}
  end

  property "memory, VMM overhead included, is never overcommitted by a placement" do
    check all(snap <- gen_snapshot(), max_runs: 300) do
      placements = placements(Plan.plan(snap))

      for box <- snap.boxes, Enum.any?(placements, &(&1.box_id == box.id)) do
        {mem, _, _, _} = allocation(snap, box, placements)
        assert mem <= Plan.allocatable_memory_mib(box)
      end
    end
  end

  property "every placement fits: vCPUs, per-VM limits, VM count, arch, state" do
    check all(snap <- gen_snapshot(), max_runs: 300) do
      placements = placements(Plan.plan(snap))

      for p <- placements do
        box = Enum.find(snap.boxes, &(&1.id == p.box_id))
        size = Map.fetch!(snap.sizes, p.size_id)
        job = Enum.find(snap.jobs, &(&1.id == p.job_id))
        {_, vcpus, count, _} = allocation(snap, box, placements)

        assert box.online
        assert vcpus <= Plan.allocatable_vcpus(box)
        assert size.vcpus <= box.caps.max_vcpus_per_vm
        assert is_nil(box.max_vms) or count <= box.max_vms
        assert job.arch == :any or Atom.to_string(job.arch) == box.guest_arch
      end
    end
  end

  property "no job gets two placements, and covered jobs get none" do
    check all(snap <- gen_snapshot(), max_runs: 300) do
      ids = placements(Plan.plan(snap)) |> Enum.map(& &1.job_id)
      assert ids == Enum.uniq(ids)
    end
  end

  property "with room to spare, every queued job's class gets its supply" do
    check all(
            n <- integer(1..30),
            repos <- list_of(member_of(["repo-a", "repo-b"]), length: n)
          ) do
      big = box("big", vcpus: 1024, memory_mib: 4_000_000, vm_area_mib: 100_000_000, max_vms: nil)
      jobs = for {r, i} <- Enum.with_index(repos, 1), do: job(i, repo_id: r)

      rs =
        for r <- ["repo-a", "repo-b"],
            do: %{id: r, priority: 0, max_concurrent: nil, allowed_boxes: nil}

      placed = placements(Plan.plan(snapshot(boxes: [big], jobs: jobs, repos: rs)))
      assert length(placed) == n
    end
  end

  property "two waiting repos share a full box evenly" do
    check all(cap <- integer(2..12), extra <- integer(0..10)) do
      b = box("a", vcpus: 1024, memory_mib: 4_000_000, vm_area_mib: 100_000_000, max_vms: cap)

      jobs =
        for(n <- 1..(cap + extra), do: job(n, repo_id: "repo-a")) ++
          for(n <- 100..(100 + cap + extra), do: job(n, repo_id: "repo-b"))

      rs =
        for r <- ["repo-a", "repo-b"],
            do: %{id: r, priority: 0, max_concurrent: nil, allowed_boxes: nil}

      counts =
        placements(Plan.plan(snapshot(boxes: [b], jobs: jobs, repos: rs)))
        |> Enum.frequencies_by(& &1.repo_id)

      assert abs(Map.get(counts, "repo-a", 0) - Map.get(counts, "repo-b", 0)) <= 1
    end
  end

  property "an offline box's idle VMs never cover demand" do
    check all(k <- integer(1..5)) do
      boxes = [
        box("off", online: false),
        box("on", vcpus: 1024, memory_mib: 4_000_000, vm_area_mib: 100_000_000)
      ]

      vms = for i <- 1..k, do: vm(i, "box-off", state: "idle")
      jobs = for n <- 1..k, do: job(n)
      assert length(placements(Plan.plan(snapshot(boxes: boxes, vms: vms, jobs: jobs)))) == k
    end
  end

  property "excess idle VMs are reaped once the grace has passed, never more than the excess" do
    check all(idle <- integer(0..8), queued <- integer(0..8)) do
      vms = for i <- 1..idle//1, do: vm(i, "box-a", state: "idle", idle_at: now() - 1000)
      jobs = for n <- 1..queued//1, do: job(n)
      cs = %{{"repo-a", ["crew-m"]} => %{excess_since: now() - 60_000}}

      reaps =
        for {:reap, id, :excess} <- Plan.plan(snapshot(vms: vms, jobs: jobs, class_state: cs)),
            do: id

      assert length(reaps) == max(idle - queued, 0)
    end
  end

  property "a stalled class's jobs are blocked and not placed" do
    check all(n <- integer(1..10)) do
      cs = %{{"repo-a", ["crew-m"]} => %{stalled_until: now() + 1}}
      actions = Plan.plan(snapshot(jobs: for(i <- 1..n, do: job(i)), class_state: cs))
      assert placements(actions) == []

      assert Enum.count(actions, &match?({:reasons, _, "GitHub isn't assigning" <> _, nil}, &1)) ==
               n
    end
  end
end
