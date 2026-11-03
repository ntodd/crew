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
