# For tests/19-usage.spec.js only (E2E_SEED=seeds/usage.exs): three boxes
# and two weeks of VMs and the jobs they ran, on several sizes, rolled up
# as Crew.Usage.Rollup would have (§16.6). Among them:
#
#   - a VM requested before midnight that ran its job after it;
#   - a VM reaped while idle, which never took a job;
#   - a VM that failed while booting.
#
# The boxes report samples for the last two days only, so older days'
# use shows as a dash. Nothing is left running, and no agent connects.
import Ecto.Query

alias Crew.Boxes.Box
alias Crew.Jobs.Job
alias Crew.Repo
alias Crew.VMs.VM

:rand.seed(:exsss, {90, 16, 6})

caps = fn vcpus, memory ->
  %{
    "driver" => "null",
    "driver_version" => "0.1.0",
    "guest_arch" => "arm64",
    "vcpus" => vcpus,
    "memory_mib" => memory,
    "vm_area_mib" => 409_600,
    "max_vcpus_per_vm" => vcpus,
    "max_memory_mib_per_vm" => memory,
    "vmm_overhead_mib" => 64,
    "features" => [],
    "virtualized" => false,
    "hypervisor_vendor" => nil,
    "firewall_ok" => true
  }
end

box = fn name, vcpus, memory ->
  {public, _} = CrewProtocol.Auth.generate_keypair()
  c = caps.(vcpus, memory)

  Repo.insert!(%Box{
    name: name,
    type: "linux-metal",
    driver: "null",
    guest_arch: "arm64",
    public_key: public,
    key_fingerprint: CrewProtocol.Auth.fingerprint(public),
    agent_version: "0.1.0",
    protocol_version: CrewProtocol.version(),
    capabilities: c,
    pinned_capabilities: c,
    firewall_ok: true
  })
end

boxes = [box.("rack-1", 32, 131_072), box.("rack-2", 32, 131_072), box.("m3-mini", 12, 49_152)]

installation =
  Repo.insert!(%Crew.Repos.Installation{
    github_id: 990_002,
    account_login: "mona",
    account_type: "Organization",
    permissions: %{
      "administration" => "write",
      "actions" => "write",
      "metadata" => "read",
      "pull_requests" => "read",
      "members" => "read"
    }
  })

repos =
  for {name, id} <- [{"storefront", 990_201}, {"payments", 990_202}, {"docs", 990_203}] do
    Repo.insert!(%Crew.Repos.Repo{
      installation_id: installation.id,
      github_id: id,
      full_name: "mona/#{name}",
      private: true,
      enabled: true,
      fork_prs: "refuse",
      priority: 0
    })
  end

sizes = Map.new(Crew.Sizes.list(), &{&1.name, &1})
jobs = %{"storefront" => ~w(test lint e2e build), "payments" => ~w(test integration), "docs" => ~w(build)}
now = DateTime.utc_now() |> DateTime.truncate(:second)
today = DateTime.to_date(now)
midnight = fn day -> DateTime.new!(day, ~T[00:00:00], "Etc/UTC") end
usec = fn t -> t && %{t | microsecond: {0, 6}} end
counter = :counters.new(1, [])

next = fn ->
  :counters.add(counter, 1, 1)
  :counters.get(counter, 1)
end

# One VM, and its job when it ran one. `marks` are seconds after
# `requested`: idle, busy, finished, failed, destroyed (nil to skip).
vm = fn box, repo, size, requested, {idle, busy, finished, failed, destroyed}, job ->
  n = next.()
  at = fn s -> s && usec.(DateTime.add(requested, s)) end
  s = sizes[size]

  v =
    Repo.insert!(%VM{
      box_id: box.id,
      name: "crew-seed-#{n}",
      repo_id: repo.id,
      class_key: ["crew-#{size}"],
      class_hash: VM.class_hash(["crew-#{size}"]),
      size_id: s.id,
      vcpus: s.vcpus,
      memory_mib: s.memory_mib,
      disk_gib: s.disk_gib,
      vmm_overhead_mib: 64 + CrewProtocol.GuestMemory.reserve_mib(s.memory_mib),
      state: "destroyed",
      fail_reason: failed && "boot_timeout",
      deadline: at.(22_500),
      requested_at: usec.(requested),
      idle_at: at.(idle),
      busy_at: at.(busy),
      finished_at: at.(finished),
      failed_at: at.(failed),
      destroyed_at: at.(destroyed)
    })

  if job do
    Repo.insert!(%Job{
      repo_id: repo.id,
      github_id: 9_900_000 + n,
      github_run_id: 9_800_000 + n,
      name: job,
      workflow_name: if(job in ~w(integration), do: "Nightly", else: "CI"),
      labels: ["crew-#{size}"],
      label_key: ["crew-#{size}"],
      size_id: s.id,
      arch: "arm64",
      classification: "ours",
      gh_state: "completed",
      gh_state_rank: 3,
      conclusion: if(rem(n, 9) == 0, do: "failure", else: "success"),
      runner_name: v.name,
      vm_id: v.id,
      seen_at: usec.(requested),
      queued_at: usec.(requested),
      started_at: at.(busy),
      completed_at: at.(finished),
      vcpus: s.vcpus,
      memory_mib: s.memory_mib
    })
  end
end

# Two weeks of ordinary days, busier on weekdays, up to now today.
for back <- 13..0//-1, day = Date.add(today, -back) do
  weekday? = Date.day_of_week(day) in 1..5

  for b <- boxes, _ <- 1..if(weekday?, do: 30 + :rand.uniform(15), else: 4 + :rand.uniform(6)) do
    requested = DateTime.add(midnight.(day), 3600 * 6 + :rand.uniform(3600 * 14))

    if DateTime.before?(DateTime.add(requested, 4000), now) do
      repo = Enum.random(repos)
      name = repo.full_name |> String.split("/") |> List.last()
      job = Enum.random(jobs[name])
      size = Enum.random(if b.name == "m3-mini", do: ~w(xs s m), else: ~w(s m l xl))
      boot = 20 + :rand.uniform(25)
      idle = boot + 5 + :rand.uniform(90)
      run = 120 + :rand.uniform(2400)
      vm.(b, repo, size, requested, {boot, idle, idle + run, nil, idle + run + 5 + :rand.uniform(10)}, job)
    end
  end
end

[rack1, rack2, mini] = boxes
[storefront, payments, docs] = repos
yesterday = Date.add(today, -1)

# Requested at 23:52 yesterday, its job ran past midnight.
vm.(rack1, storefront, "l", DateTime.add(midnight.(today), -480), {35, 60, 1560, nil, 1570}, "e2e")

# Reaped while idle: the job it was for went to another VM.
vm.(rack2, payments, "m", DateTime.add(midnight.(yesterday), 3600 * 15), {30, nil, 330, nil, 336}, nil)

# Failed while booting.
vm.(mini, docs, "s", DateTime.add(midnight.(yesterday), 3600 * 11), {nil, nil, nil, 120, 128}, nil)

# Samples for the last two days, one every 15 s (each counts in full).
since = DateTime.to_unix(midnight.(yesterday))

for b <- boxes do
  since
  |> Stream.iterate(&(&1 + 15))
  |> Stream.take_while(&(&1 <= DateTime.to_unix(now)))
  |> Stream.map(fn t ->
    %{
      box_id: b.id,
      t: t,
      cpu_pct: 20.0,
      mem_used_mib: 30_000,
      mem_total_mib: b.capabilities["memory_mib"],
      swap_used_mib: 0,
      load1: 2.0,
      disk_used_mib: 100_000,
      disk_total_mib: 1_000_000,
      vm_area_free_mib: 300_000,
      cache_used_mib: 0,
      vms_running: 2
    }
  end)
  |> Stream.chunk_every(1000)
  |> Enum.each(&Repo.insert_all(Crew.Metrics.BoxMetric, &1))
end

:ok = Crew.Usage.roll_up(today)

IO.puts(
  "usage seed: #{Repo.aggregate(VM, :count)} VMs, #{Repo.aggregate(Job, :count)} jobs, " <>
    "#{Repo.aggregate(from(r in Crew.Usage.RolledDay), :count)} days rolled up"
)
