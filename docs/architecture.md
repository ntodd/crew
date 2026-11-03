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
