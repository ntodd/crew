defmodule Crew.Scheduler.PlanSparePropertyTest do
  @moduledoc """
  What spare jobs (§7.2) promise regular ones, over generated snapshots
  whose classes may hold jobs and VMs of either tier.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Crew.PlanFixtures

  alias Crew.Scheduler.Plan
  alias CrewProtocol.GuestMemory

  @sizes [size("s", 2, 4096, 40), size("m", 4, 8192, 60), size("l", 8, 16_384, 100)]
  @repos ["repo-a", "repo-b", "repo-c"]
  @projected ~w(requested starting booted)

  defp gen_box do
    gen all(
          n <- integer(1..1000),
          vcpus <- integer(2..64),
          mem_gib <- integer(4..256),
          area_gib <- integer(100..2000),
          arch <- member_of(["arm64", "x64"]),
          online <- frequency([{4, constant(true)}, {1, constant(false)}]),
          max_vms <- one_of([constant(nil), integer(1..20)]),
          overhead <- member_of([64, 128]),
          spare_pct <- one_of([constant(nil), integer(0..100), member_of([0, 50, 100])])
        ) do
      box("b#{n}",
        vcpus: vcpus,
        memory_mib: mem_gib * 1024,
        vm_area_mib: area_gib * 1024,
        guest_arch: arch,
        online: online,
        max_vms: max_vms,
        vmm_overhead_mib: overhead,
        spare_pct: spare_pct
      )
    end
  end

  defp gen_job_spec do
    tuple(
      {member_of(@repos), member_of(@sizes), member_of([:any, :arm64, :x64]), boolean(),
       boolean()}
    )
  end

  # A class is (repo, key); the key may or may not say -spare whatever the
  # tier, as in the rename hand-over.
  defp key(size, spare_key?), do: ["crew-#{size.name}" <> if(spare_key?, do: "-spare", else: "")]

  defp to_jobs(specs, from) do
    specs
    |> Enum.with_index(from)
    |> Enum.map(fn {{repo, size, arch, spare, spare_key?}, n} ->
      job(n,
        repo_id: repo,
        size_id: size.id,
        arch: arch,
        spare: spare,
        label_key: key(size, spare_key?)
      )
    end)
  end

  defp gen_snapshot do
    gen all(
          boxes <- uniq_list_of(gen_box(), uniq_fun: & &1.id, min_length: 1, max_length: 5),
          job_specs <- list_of(gen_job_spec(), max_length: 50),
          vm_specs <-
            list_of(
              tuple(
                {member_of(boxes), member_of(@sizes), member_of(@repos),
                 member_of(~w(requested starting booted idle busy finished failed)), boolean(),
                 boolean()}
              ),
              max_length: 30
            ),
          max_concurrent <- list_of(one_of([constant(nil), integer(1..10)]), length: 3),
          allowed <- list_of(one_of([constant(nil), constant(:some)]), length: 3),
          backoff <- list_of(member_of(@sizes), max_length: 2)
        ) do
      vms =
        vm_specs
        |> Enum.with_index(1)
        |> Enum.map(fn {{box, size, repo, state, spare, spare_key?}, n} ->
          vm(n, box.id,
            repo_id: repo,
            state: state,
            spare: spare,
            vcpus: size.vcpus,
            memory_mib: size.memory_mib,
            disk_gib: size.disk_gib,
            vmm_overhead_mib: Plan.overhead_mib(box, size.memory_mib),
            job_id: if(state in ~w(busy finished), do: "j#{n}"),
            label_key: key(size, spare_key?),
            idle_at: if(state == "idle", do: now() - 1000)
          )
        end)

      repos =
        for {{r, mc}, a} <- @repos |> Enum.zip(max_concurrent) |> Enum.zip(allowed) do
          allowed_boxes = if a == :some, do: boxes |> Enum.take(2) |> Enum.map(& &1.id)
          repo(r, max_concurrent: mc, allowed_boxes: allowed_boxes)
        end

      class_state =
        for size <- backoff, into: %{} do
          {{"repo-a", key(size, false)}, %{backoff_until: now() + 10_000, last_error: "boom"}}
        end

      snapshot(
        boxes: boxes,
        sizes: @sizes,
        jobs: to_jobs(job_specs, 1),
        vms: vms,
        repos: repos,
        class_state: class_state
      )
    end
  end

  defp spare?(x), do: Map.get(x, :spare, false)

  # -- an independent account of a box's allocations ---------------------------

  defp vm_mem(vm), do: vm.memory_mib + vm.vmm_overhead_mib

  defp placed_vm(snap, box, p) do
    size = Map.fetch!(snap.sizes, p.size_id)

    %{
      memory_mib: size.memory_mib,
      vmm_overhead_mib: box.caps.vmm_overhead_mib + GuestMemory.reserve_mib(size.memory_mib),
      vcpus: size.vcpus,
      disk_gib: size.disk_gib,
      state: "requested",
      spare: p.spare
    }
  end

  defp pct(box), do: box.spare_pct || 50

  defp within_share?(box, vms) do
    spare = Enum.filter(vms, & &1.spare)
    mem = spare |> Enum.map(&vm_mem/1) |> Enum.sum()
    vcpus = spare |> Enum.map(& &1.vcpus) |> Enum.sum()

    mem * 100 <= pct(box) * Plan.allocatable_memory_mib(box) and
      vcpus * 100 <= pct(box) * Plan.allocatable_vcpus(box) and
      (is_nil(box.max_vms) or length(spare) <= div(pct(box) * box.max_vms, 100))
  end

  # Each placement in order, with the box's allocations before it.
  defp walk(snap, actions) do
    existing = Enum.group_by(snap.vms, & &1.box_id)
    boxes = Map.new(snap.boxes, &{&1.id, &1})

    {steps, _} =
      Enum.map_reduce(placements(actions), existing, fn p, acc ->
        box = Map.fetch!(boxes, p.box_id)
        before = Map.get(acc, box.id, [])
        vm = placed_vm(snap, box, p)
        {{p, box, before, vm}, Map.put(acc, box.id, before ++ [vm])}
      end)

    steps
  end

  property "adding queued spare jobs doesn't change what happens to the regular ones" do
    check all(
            snap <- gen_snapshot(),
            extra <- list_of(gen_job_spec(), min_length: 1, max_length: 20),
            max_runs: 300
          ) do
      spare_jobs = extra |> to_jobs(1001) |> Enum.map(&%{&1 | spare: true})
      regular = for j <- snap.jobs, not spare?(j), into: MapSet.new(), do: j.id

      about_regular = fn actions ->
        Enum.filter(actions, fn
          {:place, p} -> MapSet.member?(regular, p.job_id)
          {:reasons, id, _, _} -> MapSet.member?(regular, id)
          _ -> false
        end)
      end

      before = about_regular.(Plan.plan(snap))
      after_ = about_regular.(Plan.plan(%{snap | jobs: snap.jobs ++ spare_jobs}))
      assert after_ == before
    end
  end

  property "every spare placement leaves its box within its spare share" do
    check all(snap <- gen_snapshot(), max_runs: 300) do
      for {p, box, before, vm} <- walk(snap, Plan.plan(snap)), p.spare do
        assert within_share?(box, before), "#{box.name} was over its share before"
        assert within_share?(box, before ++ [vm]), "#{box.name} went over its share"
      end
    end
  end

  property "no spare placement on a box a waiting regular unit could have used" do
    check all(snap <- gen_snapshot(), max_runs: 300) do
      actions = Plan.plan(snap)
      jobs = Map.new(snap.jobs, &{&1.id, &1})

      # Regular units that looked for a box and found none: a wait reason
      # that isn't the class's backoff.
      waiting =
        for {:reasons, id, nil, wait} <- actions,
            is_binary(wait),
            not String.starts_with?(wait, "Crew can't start runners"),
            job = jobs[id],
            not spare?(job),
            do: job

      kept =
        for job <- waiting,
            box <- snap.boxes,
            could_have_used?(snap, job, box),
            into: MapSet.new(),
            do: box.id

      for p <- placements(actions), p.spare do
        refute MapSet.member?(kept, p.box_id)
      end
    end
  end

  defp could_have_used?(snap, job, box) do
    allowed = snap.repos[job.repo_id][:allowed_boxes]

    (is_nil(allowed) or box.id in allowed) and Plan.arch_ok?(box, job.arch) and box.online and
      not box.draining and not box.needs_approval and box.firewall_ok and
      (is_nil(box.quarantined_until) or box.quarantined_until <= snap.now) and
      elem(Plan.usable_image(snap, box), 0) != nil and
      Plan.could_hold?(box, Map.fetch!(snap.sizes, job.size_id))
  end

  property "every placement, regular or spare, fits what's on its box" do
    check all(snap <- gen_snapshot(), max_runs: 300) do
      for {p, box, before, vm} <- walk(snap, Plan.plan(snap)) do
        size = Map.fetch!(snap.sizes, p.size_id)
        after_ = before ++ [vm]

        assert after_ |> Enum.map(&vm_mem/1) |> Enum.sum() <= Plan.allocatable_memory_mib(box)
        assert after_ |> Enum.map(& &1.vcpus) |> Enum.sum() <= Plan.allocatable_vcpus(box)

        projected =
          box.vm_area_free_mib -
            (after_
             |> Enum.filter(&(&1.state in @projected))
             |> Enum.map(&(0.5 * &1.disk_gib * 1024))
             |> Enum.sum())

        assert projected >= 0.15 * box.caps.vm_area_mib
        assert size.vcpus <= box.caps.max_vcpus_per_vm
        assert GuestMemory.boot_mib(size.memory_mib) <= box.caps.max_memory_mib_per_vm
        assert is_nil(box.max_vms) or length(after_) <= box.max_vms
      end
    end
  end
end
