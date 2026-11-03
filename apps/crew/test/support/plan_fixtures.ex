defmodule Crew.PlanFixtures do
  @moduledoc "Snapshots for `Crew.Scheduler.Plan` tests, as plain maps."

  @now 1_800_000_000_000

  def now, do: @now

  def size(name \\ "m", vcpus \\ 4, memory_mib \\ 8192, disk_gib \\ 60),
    do: %{
      id: "size-" <> name,
      name: name,
      vcpus: vcpus,
      memory_mib: memory_mib,
      disk_gib: disk_gib
    }

  def box(name, attrs \\ []) do
    attrs = Map.new(attrs)
    vcpus = Map.get(attrs, :vcpus, 16)
    memory = Map.get(attrs, :memory_mib, 65_536)
    area = Map.get(attrs, :vm_area_mib, 409_600)

    %{
      id: "box-" <> name,
      name: name,
      online: Map.get(attrs, :online, true),
      draining: Map.get(attrs, :draining, false),
      quarantined_until: Map.get(attrs, :quarantined_until),
      needs_approval: Map.get(attrs, :needs_approval, false),
      firewall_ok: Map.get(attrs, :firewall_ok, true),
      guest_arch: Map.get(attrs, :guest_arch, "arm64"),
      caps: %{
        vcpus: vcpus,
        memory_mib: memory,
        vm_area_mib: area,
        max_vcpus_per_vm: Map.get(attrs, :max_vcpus_per_vm, vcpus),
        max_memory_mib_per_vm: Map.get(attrs, :max_memory_mib_per_vm, memory),
        vmm_overhead_mib: Map.get(attrs, :vmm_overhead_mib, 64)
      },
      allocatable_vcpus_override: Map.get(attrs, :allocatable_vcpus_override),
      allocatable_memory_mib_override: Map.get(attrs, :allocatable_memory_mib_override),
      reserve_vcpus: Map.get(attrs, :reserve_vcpus, 1),
      reserve_memory_mib: Map.get(attrs, :reserve_memory_mib),
      cpu_overcommit: Map.get(attrs, :cpu_overcommit, 1.5),
      max_vms: Map.get(attrs, :max_vms),
      vm_area_free_mib: Map.get(attrs, :vm_area_free_mib, area),
      last_repo_ran_at: Map.get(attrs, :last_repo_ran_at, %{})
    }
  end

  def job(n, attrs \\ []) do
    attrs = Map.new(attrs)
    repo = Map.get(attrs, :repo_id, "repo-a")
    key = Map.get(attrs, :label_key, ["crew-m"])

    %{
      id: "job-#{n}",
      github_id: Map.get(attrs, :github_id, n),
      repo_id: repo,
      class: {repo, key},
      label_key: key,
      size_id: Map.get(attrs, :size_id, "size-m"),
      arch: Map.get(attrs, :arch, :any),
      queued_at: Map.get(attrs, :queued_at, @now - 60_000 + n),
      blocked_reason: Map.get(attrs, :blocked_reason)
    }
  end

  def vm(n, box_id, attrs \\ []) do
    attrs = Map.new(attrs)
    repo = Map.get(attrs, :repo_id, "repo-a")
    key = Map.get(attrs, :label_key, ["crew-m"])

    %{
      id: "vm-#{n}",
      box_id: box_id,
      repo_id: repo,
      class: {repo, key},
      vcpus: Map.get(attrs, :vcpus, 4),
      memory_mib: Map.get(attrs, :memory_mib, 8192),
      disk_gib: Map.get(attrs, :disk_gib, 60),
      vmm_overhead_mib: Map.get(attrs, :vmm_overhead_mib, 64),
      state: Map.get(attrs, :state, "idle"),
      job_id: Map.get(attrs, :job_id),
      requested_at: Map.get(attrs, :requested_at, @now - 120_000 + n),
      idle_at: Map.get(attrs, :idle_at)
    }
  end

  def repo(id, attrs \\ []),
    do: Map.merge(%{id: id, priority: 0, max_concurrent: nil, allowed_boxes: nil}, Map.new(attrs))

  def snapshot(attrs \\ []) do
    attrs = Map.new(attrs)
    boxes = Map.get(attrs, :boxes, [box("a")])

    %{
      now: Map.get(attrs, :now, @now),
      settings: Map.merge(%{idle_grace_s: 30, idle_max_s: 600}, Map.get(attrs, :settings, %{})),
      sizes: Map.get(attrs, :sizes, [size()]) |> Map.new(&{&1.id, &1}),
      repos:
        Map.get(attrs, :repos, [
          %{id: "repo-a", priority: 0, max_concurrent: nil, allowed_boxes: nil}
        ])
        |> Map.new(&{&1.id, &1}),
      boxes: boxes,
      images:
        Map.get(attrs, :images, %{
          "arm64" => %{default: "img-1", recent_defaults: ["img-1"]},
          "x64" => %{default: "img-x", recent_defaults: ["img-x"]}
        }),
      box_images:
        Map.get_lazy(attrs, :box_images, fn ->
          for b <- boxes, img <- ["img-1", "img-x"], into: %{}, do: {{b.id, img}, "ready"}
        end),
      jobs: Map.get(attrs, :jobs, []),
      vms: Map.get(attrs, :vms, []),
      class_state: Map.get(attrs, :class_state, %{})
    }
  end

  def placements(actions), do: for({:place, p} <- actions, do: p)
end
