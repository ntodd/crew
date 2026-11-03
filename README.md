# Crew

Crew runs GitHub Actions jobs on hardware you own, each job in its own
throwaway virtual machine. Nothing is assigned to a repo ahead of time:

1. GitHub queues a job that asks for a Crew label (`runs-on: crew-m`).
2. The control plane picks a box with room and asks GitHub for a
   single-use (JIT) runner registration.
3. It tells that box's agent to boot a VM with the registration.
4. The runner takes the job, runs it and exits. The VM is destroyed.

The design is in [docs/crew_spec.md](docs/crew_spec.md). Crew copies
[Foreman](https://github.com/ntodd/foreman) wherever it can: the sign-in,
the agent's signed connect, its updater and the UI foundations all come
from there.

## Layout

A monorepo of separate Mix projects. The pieces ship on different
schedules, so it isn't an umbrella.

```
apps/
  crew/            # Phoenix control plane
  crew_agent/      # agent release: linux-amd64, linux-arm64, darwin-arm64
  crew_protocol/   # shared structs + validation: commands, events, guest API, labels
  crew_cache/      # registry cache + guest DNS
  crew_guest/      # guest init release, baked into the guest image
native/
  crew-vmctl/      # Go: Linux root helper with fixed verbs
  crew-vz/         # Go: VZ helper (one per VM) and crew-vzd supervisor
images/
  guest/           # guest image build
  flatcar/         # Butane templates
docs/
e2e/
```

## Development

Tool versions are in `mise.toml`.

```sh
cd apps/crew_protocol && mix deps.get && mix test
```
