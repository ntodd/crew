# For tests/20-spare.spec.js only (E2E_SEED=seeds/spare.exs): spare jobs
# (§7.2) on one box. Its spare share (50%) is full: three spare `m` VMs
# run a flake hunt's legs, next to one regular `l` VM. Two more spare legs
# and a regular `xl` job are queued.
#
# No agent connects, so the box is offline and the queued jobs say so;
# the pages show the tiers, the share and the counts.
alias Crew.Boxes.Box
alias Crew.Jobs.{Job, RunAttempt}
alias Crew.Repo
alias Crew.VMs.VM

caps = %{
  "driver" => "null",
  "driver_version" => "0.1.0",
  "guest_arch" => "arm64",
  "vcpus" => 24,
  "memory_mib" => 65_536,
  "vm_area_mib" => 786_432,
  "max_vcpus_per_vm" => 24,
  "max_memory_mib_per_vm" => 65_536,
  "vmm_overhead_mib" => 64,
  "features" => [],
  "virtualized" => false,
  "hypervisor_vendor" => nil,
  "firewall_ok" => true
}

{public, _} = CrewProtocol.Auth.generate_keypair()

box =
  Repo.insert!(%Box{
    name: "rack-1",
    type: "linux-metal",
    driver: "null",
    guest_arch: "arm64",
    public_key: public,
    key_fingerprint: CrewProtocol.Auth.fingerprint(public),
    agent_version: "0.1.0",
    protocol_version: CrewProtocol.version(),
    capabilities: caps,
    pinned_capabilities: caps,
    firewall_ok: true,
    spare_pct: 50
  })

installation =
  Repo.insert!(%Crew.Repos.Installation{
    github_id: 990_003,
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

[flakes, storefront] =
  for {name, id} <- [{"flakes", 990_301}, {"storefront", 990_302}] do
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
now = DateTime.utc_now()
ago = fn s -> DateTime.add(now, -s) end

attempt = fn repo, run_id, workflow ->
  Repo.insert!(%RunAttempt{
    repo_id: repo.id,
    github_run_id: run_id,
    run_attempt: 1,
    run_number: rem(run_id, 1000),
    workflow_name: workflow,
    event: "schedule",
    head_branch: "main",
    head_sha: "5a7e1d0c0ffee5a7e1d0c0ffee5a7e1d0c0ffee5",
    head_commit_message: "Hunt for flakes",
    actor_login: "mona",
    is_fork: false,
    status: "in_progress",
    gh_created_at: ago.(1200),
    gh_updated_at: now
  })
end

hunt = attempt.(flakes, 9_700_001, "Flake hunt")
ci = attempt.(storefront, 9_700_002, "CI")

# A job, queued or running on `vm`.
job = fn run, repo, n, name, label, vm ->
  size = sizes[label |> String.replace_prefix("crew-", "") |> String.replace_suffix("-spare", "")]

  Repo.insert!(%Job{
    repo_id: repo.id,
    run_attempt_id: run.id,
    github_id: 9_600_000 + n,
    github_run_id: run.github_run_id,
    run_attempt: 1,
    name: name,
    workflow_name: run.workflow_name,
    labels: [label],
    label_key: [label],
    size_id: size.id,
    arch: "any",
    spare: String.ends_with?(label, "-spare"),
    classification: "ours",
    gh_state: if(vm, do: "in_progress", else: "queued"),
    gh_state_rank: if(vm, do: 2, else: 1),
    runner_name: vm && vm.name,
    vm_id: vm && vm.id,
    seen_at: ago.(900 - n * 60),
    queued_at: ago.(900 - n * 60),
    started_at: vm && ago.(700 - n * 60),
    last_event_at: now
  })
end

# A busy VM of `label`'s size, and the job it runs.
running = fn run, repo, n, name, label ->
  size = sizes[label |> String.replace_prefix("crew-", "") |> String.replace_suffix("-spare", "")]

  vm =
    Repo.insert!(%VM{
      box_id: box.id,
      name: "crew-seed-spare-#{n}",
      repo_id: repo.id,
      class_key: [label],
      class_hash: VM.class_hash([label]),
      spare: String.ends_with?(label, "-spare"),
      size_id: size.id,
      vcpus: size.vcpus,
      memory_mib: size.memory_mib,
      disk_gib: size.disk_gib,
      vmm_overhead_mib: 64 + CrewProtocol.GuestMemory.reserve_mib(size.memory_mib),
      state: "busy",
      deadline: DateTime.add(now, 6 * 3600),
      requested_at: ago.(800 - n * 60),
      started_at: ago.(790 - n * 60),
      booted_at: ago.(770 - n * 60),
      idle_at: ago.(760 - n * 60),
      busy_at: ago.(700 - n * 60)
    })

  j = job.(run, repo, n, name, label, vm)
  Repo.update!(Ecto.Changeset.change(vm, job_id: j.id))
end

# Half of rack-1 holds 3 spare m VMs (§8.3's spare worked example).
for leg <- 1..3, do: running.(hunt, flakes, leg, "flake-hunt (#{leg}, 5)", "crew-m-spare")
running.(ci, storefront, 4, "build", "crew-l")

for leg <- 4..5, do: job.(hunt, flakes, leg + 1, "flake-hunt (#{leg}, 5)", "crew-m-spare", nil)
job.(ci, storefront, 7, "e2e", "crew-xl", nil)
