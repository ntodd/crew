# Architecture

[crew_spec.md](crew_spec.md) is the design. This file records what
building it settled: the spike results, and decisions the spec left to
the build.

## Spike results

| # | Result |
|---|---|
| S2 | Resolved before the build, by ntodd/foreman#132 (spec §24). |

The other spikes are recorded here as they run.

## Protocol notes

- VM event times (`at`, `t`) are Unix milliseconds; box metrics' `t` too.
  The control plane stores metrics in Unix seconds (§22).
- A log epoch is a random 64-bit value, carried as 16 lowercase hex
  digits so it survives JSON in any client.
- `vm.start`'s `policy` carries `repo_full_name` as well as `fork_prs`,
  since the guest's payload needs both (§13.4).

## GitHub intake notes

- **Webhook dedupe.** §6.2 makes Oban unique on `(event, object id,
  action)`. The object is the job for `workflow_job` and the run
  *attempt* for `workflow_run`, so a re-run's events aren't taken for
  the first attempt's. Installation events are keyed by their delivery:
  adding two repos in a row is two changes, not one.
- **Fork refusal** happens wherever a fork PR's Crew job first meets its
  run attempt: when the run arrives after its jobs, or when a job
  arrives after its run (including the reconciler's sweep). The cancel
  is unique per run attempt, so it and its audit happen once.
- **Budget retries.** Req's own retries are off for installation calls.
  Reads are retried on 5xx and transport errors, each try through the
  budget; writes aren't retried by the client.
- **Repo activity** (`repos.last_activity_at`, which the reconciler's
  skip rule reads) is written at most every 30 s per repo.

## Agent notes

- **Capability pinning.** The pinned baseline moves only when an admin
  accepts a report, so a box can't creep past it in steps under 10%.
  Smaller reports are recorded but don't move it; placement uses the
  smaller of the pinned and the latest reported value.
- **Enrollment** checks the URL (`wss://` unless `CREW_DEV=1`) before the
  join token is sent, and doesn't follow redirects.
- **Logs outlive their VM.** A VM's server holds its unacknowledged log
  batches after the VM exits, until they're acked or 5 minutes pass. A
  resend for a VM the agent no longer holds is answered `vm.log.gone`.
- **vz guests** each get their own guest API listener on
  `vms/<vm_id>/guest.sock`, pinned to that VM; the null driver and
  Firecracker share one TCP listener.
- **The inventory** lists every live VM, then the most recently exited,
  within the protocol's 1,000; exited VMs' directories go after an hour.

## Scheduler and VM lifecycle notes

- **The plan is a pure function.** `Crew.Scheduler.Plan.plan/1` takes a
  snapshot (plain maps, times in Unix milliseconds) and returns actions;
  `Crew.Scheduler` builds the snapshot and applies them. The worked
  example and the §23 properties run against the pure function.
- **Passes** run in `Crew.Scheduler`'s process: once a second, and after
  a `poke/0` (a VM changed state, an image became ready), no more than
  every 200 ms. A pass that raises is logged and the next one runs.
- **Wait reasons and blocked reasons are separate.** `blocked_reason` is
  for jobs that aren't demand (no box of their arch, a stalled class, the
  fork check); `wait_reason` is for jobs that are demand but waiting
  ("no box with 4 vCPUs free", "booting a runner on m4"). The job page
  shows the second as "Waiting · 12s · <reason>".
- **The state machine is a pure function too.** `Crew.VMs.Machine`
  covers every cell of §8.6's table; `Crew.VMs.Server` carries out its
  effects. Each transition and its `vm_events` row are one transaction.
- **A busy VM that exits goes straight through `finished` to
  `destroyed`**: the same `vm.exited` is applied to `finished`, so a VM
  that's gone doesn't hold its allocation through the finished timers.
- **A failed or finished VM that never exits** (the agent never started
  it, or lost it) asks its box for `box.inventory` every 60 s (5 s at
  first when it was never acked). A VM the inventory doesn't list is
  destroyed, per §8.6's inventory row. A `requested` VM's absence means
  nothing: its `vm.start` may still be on the way.
- **Timers** are recomputed from the stored timestamps when servers
  start at boot; a VM still `requested` at boot fails as `cp_restart`.
- **Job links** come from the webhook's `runner_name`, when it names one
  of this deployment's runners (`crew-<deployment id>-…`). A job taken by
  a runner booted for another class is flagged `taken_cross_class`.
- **The fake GitHub** (`e2e/fake-github`) registers JIT runners and
  assigns queued jobs to listening runners the way GitHub does (every
  job label among the runner's, oldest first). The null driver's fake
  guest long-polls it for a job, so the e2e suite runs real placements,
  assignments, reaps and runner deletes.
