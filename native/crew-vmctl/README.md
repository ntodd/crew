# crew-vmctl

The Firecracker box's root helper (spec §10.8, §11.3, §14.2). The agent
runs as `_crewagent` with `NoNewPrivileges`, serving the guest API to
hostile guests, so it holds no root powers. Everything that needs root
goes through crew-vmctl's fixed verbs: starting and stopping VM units,
taps, `vm_pairs`, verifying the packet filter, rebooting the box,
restarting crew-cache. It's also crew-net, which sets up the box's
network at boot.

The agent's side is `CrewAgent.Driver.Firecracker`
(`apps/crew_agent/lib/crew_agent/driver/firecracker.ex`). This file is
the contract between them.

## Build and test

```sh
cd native
make crew-vmctl   # crew-vmctl/bin/linux-{amd64,arm64}/crew-vmctl, static
make test vet     # unit tests; the verbs' logic runs against a fake host
```

- One Go module with crew-vz, every dependency vendored, built with
  `GOFLAGS=-mod=vendor GOPROXY=off`. crew-vmctl uses the standard library
  and `golang.org/x/sys/unix` (already vendored for crew-vz).
- The Linux-only parts (`vmctl/host_linux.go`) build only for Linux; on
  macOS the verbs' logic still builds and its tests run.
- CI's `vmctl` job checks `etc/nft.conf` and `etc/connlimit.rules` with
  the kernel and runs the tests on amd64 and arm64.
- `firecracker.env` pins Firecracker (1.17.0) by its tarballs' SHA-256s;
  `fetch-firecracker.sh DIR [arch]` downloads and checks it.
- The real-VM tests are the agent's `:kvm` suite, run on a Linux host
  with KVM by `kvm/run.sh` (below).

## Running it

crew-vmctl is socket-activated, not called through sudo: the agent's
`NoNewPrivileges=yes` rules out setuid helpers, and a socket keeps the
interface to one JSON request with no argv, environment or file
descriptors from the agent.

| Unit | Does |
|---|---|
| `crew-vmctl.socket` | `/run/crew/vmctl.sock`, 0660 `root:_crewagent`, `Accept=yes` |
| `crew-vmctl@.service` | One `crew-vmctl serve` per connection, as root, the connection on stdin and stdout. Sets `CREW_VM_NET`. |
| `crew-net.service` | Oneshot at boot: `crew-vmctl net-up` |
| `crew-net-site4.timer`, `crew-net-site4.service` | `crew-vmctl site4` every 10 minutes |

They're in `etc/systemd/`, shipped in the agent tarball's `etc/systemd/`;
the box's Ignition installs them into `/etc/systemd/system`. Every unit
runs `/srv/crew/root/current/bin/crew-vmctl`, and crew-vmctl runs jailer
and Firecracker from the same `bin/`: `root/<version>/` is installed by
root from the release, and `root/current` links to the one in use, all
root's. Not `agent/current/bin` as §11.3 has it: the agent can write
`agent/` (it updates itself there). The `root` prefix is a constant
under the data directory, not a setting.

crew-vmctl's settings come from its units, never from the agent:
`--data-dir` (default `/srv/crew`) and `CREW_VM_NET` (default
`10.200.0.0/16`, a /16 to /28 in private space; it must match the
agent's, and `nft.conf` names `10.200.0.0/16`). It clears its
environment at start, and runs `ip`, `nft`, `iptables-nft-*`,
`systemctl` and `systemd-run` with only `PATH=/usr/sbin:/usr/bin:/sbin:/bin`.

## Protocol

One JSON object per connection, on one line, at most 4 KiB; one JSON
line back. Unknown fields, a missing or extra argument, or a second
object are refused.

```json
{"verb": "start", "vm_id": "0195f3a2-7c4e-7b1a-9f00-0123456789ab"}
{"ok": true, "vm": {"vm_id": "…", "state": "active", "sub_state": "running", "pid": 4242}}
{"ok": false, "error": "invalid_config", "detail": "fc.json: the drive must be /srv/crew/vms/…/rootfs.ext4"}
```

`vm_id` and `boot_id` are lowercase UUIDs. `lease_index` is 1 to the VM
range's capacity less one (16,383 for a /16). `force` is a boolean.

| Verb | Arguments | Does |
|---|---|---|
| `start` | `vm_id` | Reads `vms/<vm_id>/vm.json` and `fc.json`, checks them (below), checks the packet filter itself (as `nft-verify`, refilling a short `site4` once), lays out the jail and runs the VM's unit. Refused (`already_launched`) if the unit is live or the jail directory exists: a VM is launched once. Refused (`nft_mismatch`, `site4_not_ready`) if the filter doesn't verify, whatever the agent last saw. |
| `stop` | `vm_id`, `force` | `systemctl kill --kill-whom=main --signal=SIGKILL` (force) or `systemctl stop --no-block` the unit. `not_found` if it isn't running. Only the main process, the VMM: killing the whole cgroup (systemd uses `cgroup.kill`) also kills the `ExecStopPost` forked into it a moment later, and the exit record with it. |
| `status` | `vm_id` | The unit's `ActiveState` (`gone` once systemd has dropped it), `SubState`, main PID, and the exit record once there is one. |
| `list` | | Every `crew-vm-*` unit systemd knows (`vms`), and every VM with a jail directory (`jails`), live or not: what `cleanup` would still remove. The agent cleans up any it has no live or pending record of, at start. |
| `tap-add` / `tap-del` | `lease_index` | `crewt<n>`, owned by uid and gid 200000 + n, with `<gateway>/30`, `disable_ipv6=1` and `rp_filter=1` (set before the link is up). `tap-add` makes a leftover tap again. |
| `pair-add` / `pair-del` | `lease_index` | `crewt<n> . <guest>` in `inet crew`'s `vm_pairs`. Deleting one that's gone is fine. |
| `nft-verify` | | Compares the loaded rules with the shipped ones (below): `nft_mismatch` on any difference. Then checks that `site4` holds everything crew-net puts there (more is fine): `site4_not_ready` if not. Answers `site4: {egress, prefixes}`, the egress address in it if crew-vmctl knows one. It only looks. |
| `site4` | | Refills `site4` now, as crew-net's timer does. The agent asks when it learns a new egress address. |
| `reboot` | `boot_id`, `force` | `already: true` if the box is on another boot. Without `force`, `busy` while any `crew-vm-*` unit is live. Then `systemd-run --on-active=5 systemctl reboot`. |
| `cleanup` | `vm_id` | SIGKILLs a live unit and waits for it, removes the pair and tap of the lease recorded at start, moves `console.log`, `fc.stderr` and `fc.log` into `vms/<vm_id>/` and removes the jail directory. Idempotent; fine for a VM that never started. |
| `restart-cache` | | `systemctl restart --no-block crew-cache.service` (§20.2). |
| `info` | | crew-vmctl's version, Firecracker's (`firecracker --version`) and systemd's, for `driver_version` and the systemd ≥ 252 check. |

Error codes: `bad_request`, `unknown_verb`, `invalid_config`,
`already_launched`, `not_found`, `busy`, `nft_mismatch`,
`site4_not_ready`, `id_in_use`, `failed`.

Two more commands aren't verbs, since no socket request reaches them:
`crew-vmctl exited <vm_id>` (the unit's `ExecStopPost`) and
`crew-vmctl nft-reference` (run by `nft-verify` in a new network
namespace).

## What `start` checks and lays out

The agent writes, in `vms/<vm_id>/`:

- `vm.json`: crew-vmctl reads `vm_id` (must be this one), `image.id` (a
  UUID), `size.vcpus` (1 or even, up to 32), `size.memory_mib` (1024 to
  1 TiB), `deadline` (in the future, within 7 days) and `lease_index`.
  The rest is the agent's and ignored.
- `fc.json`: Firecracker's own config format with host paths. It's
  decoded against the part of the schema Crew uses; anything else
  (`vsock`, `initrd_path`, `mmds-config`, `balloon`, `cpu-config`,
  `huge_pages`, `io_engine`, a second drive or interface, a logger or
  metrics of its own) is refused. Every value is checked:
  - `boot-source.kernel_image_path` is `images/<image.id>/kernel`;
    `boot_args` is 1 to 2048 bytes of printable ASCII;
  - `drives` is one: `rootfs`, `vms/<vm_id>/rootfs.ext4`, the read-write
    root device;
  - `machine-config` is the size's vCPUs and memory, `smt: false`;
  - `network-interfaces` is one: `eth0` on the lease's tap with the
    lease's MAC (`02:c2` and the guest address);
  - `entropy` is there;
  - every rate limiter has a bucket; sizes are 1 to 2^40, refill times 1
    to 60,000 ms.
- `rootfs.ext4`: the clone. A regular file with one link, owned by the
  agent (the connecting uid), on the jail's filesystem.

And `images/<image_id>/kernel`: a regular file owned by the agent,
world-readable and not group- or world-writable.

Files under the data directory are opened with
`openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS)`, so a symlink anywhere in
`vms/` or `images/` is refused rather than followed.

Before it lays anything out, `start` (and `tap-add`) checks the VM's
uid and gid, 200000 + the lease: a user's uid or primary gid or a
group's gid in `/etc/passwd`, `/etc/group` or Flatcar's
`/usr/share/baselayout/{passwd,group}`, or an id inside a range in
`/etc/subuid` or `/etc/subgid`, is refused (`id_in_use`), and so is a
box whose `/etc/passwd` or `/etc/group` can't be read.

crew-vmctl then lays out `jail/firecracker/<vm_id>/`. `jail/`,
`jail/firecracker/` and `<vm_id>/` are root's, 0755, and stay so;
`root/` starts out root's too, and jailer gives it to the VM's uid and
gid when it sets up the chroot.

| Path | What |
|---|---|
| `root/` | jailer's chroot (the VM's once jailer runs) |
| `root/rootfs.ext4` | A hard link to the clone, which is given to the VM's uid and gid, 0600 |
| `root/kernel` | A hard link to the image's kernel |
| `root/fc.json` | Rebuilt from the checked values: chroot paths, and crew-vmctl's own `logger` (`/fc.log`, `Warning`) and `metrics` (`/fc.metrics`). 0400, the VM's. |
| `root/fc.log`, `root/fc.metrics` | Empty regular files, 0600, the VM's |
| `lease` | The lease index, for `cleanup` |
| `console.log`, `fc.stderr` | Empty, 0640, owned by the agent, which caps the console (§11.3) |
| `exited.json` | The exit record, once the unit ends |

jailer adds `root/firecracker` (its copy of the binary) and the device
nodes.

## The unit

```
systemd-run --unit=crew-vm-<vm_id> --collect \
  -p Type=exec -p KillMode=mixed -p TimeoutStopSec=30 \
  -p MemoryMax=<memory_mib + 256>M -p MemorySwapMax=0 -p TasksMax=1024 \
  -p CPUAccounting=yes -p RuntimeMaxSec=<deadline − now> -p OOMScoreAdjust=500 \
  -p StandardOutput=append:/srv/crew/jail/firecracker/<vm_id>/console.log \
  -p StandardError=append:/srv/crew/jail/firecracker/<vm_id>/fc.stderr \
  -p LogRateLimitIntervalSec=10 -p LogRateLimitBurst=1000 \
  -p "ExecStopPost=/srv/crew/root/current/bin/crew-vmctl exited <vm_id>" \
  -- /srv/crew/root/current/bin/jailer \
       --id <vm_id> --exec-file /srv/crew/root/current/bin/firecracker \
       --uid <200000 + lease> --gid <200000 + lease> --chroot-base-dir /srv/crew/jail \
       -- --config-file /fc.json --no-api
```

Where it differs from §11.3, and why:

- **The console and stderr are in the jail directory,** not
  `vms/<vm_id>/`. systemd (root) opens them, following symlinks; the
  agent owns `vms/`, so a compromised agent could have pointed
  `console.log` at any file on the box and had the guest's console
  appended to it. Only root can change the jail directory. The agent
  owns the two files, so it can still truncate the console, and
  `cleanup` moves them into `vms/<vm_id>/`.
- **`ExecStopPost` runs `crew-vmctl exited`,** which writes
  `exited.json` from `SERVICE_RESULT`, `EXIT_CODE` and `EXIT_STATUS`
  before `--collect` forgets the unit. That's how the agent tells a
  deadline kill (`timeout`) from a guest power-off (`success`, exit 0)
  or a crash, even when it was down at the time.

The exit record:

```json
{"service_result": "timeout", "exit_code": "killed", "exit_status": "TERM", "code": 143, "at": 1800003600}
```

`code` is the exit status, or 128 plus the signal.

## crew-net

`crew-vmctl net-up` (crew-net.service, once at boot):

1. the uplink: `CREW_UPLINK` from `agent/env`, else the default route's
   interface. Not `lo`, `crew*`, `tailscale*` or `docker*`.
2. `crew0`, a dummy interface with `10.199.0.1/32`;
3. `etc/nft.conf` with `define UPLINK = "<uplink>"`, in one transaction
   that replaces `inet crew`;
4. `etc/connlimit.rules` through `iptables-nft-restore`, which replaces
   the `ip mangle` table;
5. `/run/crew/uplink`, for `nft-verify`;
6. `vm_pairs` again for any `crewt*` tap that exists (crew-net restarted
   while VMs run);
7. site4.

`crew-vmctl site4` (every 10 minutes, and the `site4` verb) flushes and
refills `site4` in one nft transaction: the uplink's connected subnets,
the egress address the agent learned (`agent/egress4`, one IPv4 address)
and `CREW_EXTRA_BLOCKED`. A prefix inside another is left out, since nft
refuses overlapping intervals.

crew-vmctl keeps the last valid egress address it read in
`/run/crew/egress4` (root's). When `agent/egress4` is missing or isn't
one IPv4 address, that one stays in `site4` rather than being dropped.
At boot crew-net runs before the agent has asked the echo service, so
`site4` starts with the address the agent wrote before the reboot
(`agent/egress4` is on the data disk), if any; the agent asks for a
refill as soon as it learns one.

`agent/env` is the agent's file, so crew-net parses it for exactly
`CREW_UPLINK` and `CREW_EXTRA_BLOCKED`, and never hands it to systemd as
an `EnvironmentFile` (it could set `LD_PRELOAD` for a root process).

## The packet filter and `nft-verify`

`etc/nft.conf` is §14.2's ruleset with three changes:

- **Pings are accepted to `10.199.0.1` only.** §14.2's rule accepts an
  echo request to any address on the host, so a guest could ping its
  gateway, other VMs' gateways and the host's uplink and tailnet
  addresses: that's the input chain, which `blocked4` and `site4` (in
  forward) don't cover. A test holds every accepting input rule to the
  service address.
- `blocked4` leaves out `255.255.255.255/32`, which `240.0.0.0/4`
  covers. nft refuses overlapping intervals in a set without
  `auto-merge`, so the spec's set doesn't load.
- **The 2048-connection cap isn't in it.** `ct count` needs
  `nft_connlimit`, and Flatcar's kernel is built without it
  (`CONFIG_NFT_CONNLIMIT` is not set in 4757.2.3). Flatcar has
  `xt_connlimit` and `nft_compat`, so the cap is
  `etc/connlimit.rules`: the same per-source count (both use
  `nf_conncount`) for new connections from `crewt*`, on input and
  forward, in the `ip mangle` table, which Crew owns on a box.

crew-vmctl embeds both files, so what crew-net loads and what
`nft-verify` checks are one copy. The tests' listings
(`ruleset/testdata/`) are recorded from them by
`ruleset/testdata/record.sh`, with the files' hash in `rules.sha256`; a
test fails when the files change and the listings weren't recorded
again.

`nft-verify` loads them into a new network namespace (`crew-vmctl
nft-reference`), lists that with `nft -j list table inet crew` and
`iptables-nft-save -t mangle`, and compares the box's listings with
those. The same binaries print both, so the comparison doesn't depend
on how a given nft version prints a ruleset (1.0.6 and 1.1.6 order
objects differently). Objects are matched by kind and name and rules by
position in their chain; handles, counters and the elements of
`vm_pairs` and `site4` are ignored. Anything else is a mismatch: a rule,
an order, a policy, a priority, a `blocked4` range, an extra chain or
set, the cap's limit. `site4`'s elements are checked separately: it must
hold everything crew-net puts there.

**When it doesn't verify:**

- `start` runs the same check itself, so no VM starts on a box whose
  filter is off, whatever the agent last saw. That costs every start the
  check: on the M3's Flatcar VM `nft-verify` takes 46 to 55 ms (most of
  it the reference load in a fresh namespace), and the agent's whole
  `vm.start` is answered in about 160 ms. Twenty starts at once load
  twenty reference rulesets, in parallel, in their own namespaces.
- The agent checks every 60 s (and when a start finds the last verdict
  bad). A filter crew-vmctl says doesn't verify, twice in a row, gets
  every VM on the box killed (`killed_stop`, detail
  `firewall_not_verified`), and no VM starts until a check passes again.
  A crew-vmctl the agent can't reach refuses starts but kills nothing
  (stops go through it too), and nor does an egress address the agent
  hasn't learned yet: neither says the filter is off.

## Real VMs: the `:kvm` suite

`apps/crew_agent/test/crew_agent/firecracker_kvm_test.exs` (tag `:kvm`,
excluded by default) boots the guest image through the agent's own start
path, crew-vmctl's socket, a systemd unit and jailer:

- the host meets §11.3's requirements and the packet filter verifies;
- a VM boots and crew-guest fetches its payload from `10.199.0.1:7777`;
  with the example JIT config crew-guest then refuses to start the runner
  and powers off, a clean exit (status 0);
- a forced stop's `vm.exited` is `killed_stop`, status 137, within a
  couple of seconds; jailer has given the chroot to the VM's uid, and
  the directory around it is root's;
- with its pair deleted the VM never reaches the guest API (`vm_pairs`
  fails closed), and with its server gone (the agent away) systemd's
  `RuntimeMaxSec` kills it at the deadline; adoption reports
  `killed_deadline`;
- with an echo service configured, starts wait until site4 holds the
  egress address, which is loaded the moment the agent records it;
- a rule added by hand: crew-vmctl's own `start` refuses, the agent's
  next check kills the running VM (`firewall_not_verified`) and refuses
  starts, and both recover once the rule is gone;
- a cleanup crew-vmctl can't do (its socket out of reach) keeps the VM's
  record, lease and jail until a retry works; a jail with no record is
  reconciled away;
- after each, nothing is left: no unit, tap, jail or clone.

`kvm/run.sh` runs it on a Linux host with KVM, from a checkout:

```sh
sudo CREW_REAL_IMAGE_DIR=/srv/crew/kvm-image native/crew-vmctl/kvm/run.sh   # --keep to leave it set up
```

- `CREW_REAL_IMAGE_DIR` holds `Image` (arm64) or `kernel`, and
  `rootfs.ext4`. Put it on `/srv/crew`'s filesystem (not in `agent/`,
  `root/`, `vms/`, `images/` or `jail/`) and it's reflinked rather than
  copied.
- `/srv/crew` must be an XFS with reflink, and not a real box's: the
  script refuses an `agent/` or `root/` it didn't make.
- It fetches and checks the pinned Firecracker, builds crew-vmctl,
  installs both into `root/kvm-test` with `root/current` linking to it,
  checks the units with `systemd-analyze verify` in one boot transaction
  (a target that wants them with `sockets.target` and `basic.target`;
  any output fails the run, so an ordering cycle between them does),
  and installs the units (runtime units in `/run/systemd/system`,
  with the socket's group root, since the tests run as root), starts
  crew-net and the socket, runs the suite, checks the host for anything
  left (units, taps, `vm_pairs` elements, jails) and takes it all down.
- With `go` and `mix` on PATH it uses them. Otherwise (Flatcar) it runs
  the pinned `golang` and `hexpm/elixir` images through a dockerd of its
  own (a transient unit, no iptables rules, no bridge), stopped at the
  end; the agent's container has the host's network, cgroups, `/srv/crew`
  and `/run/crew`. Caches are in `/var/lib/crew-kvm`.

On the M3's Flatcar VM (arm64, nested virtualization, Flatcar 4757.2.3,
systemd 260, nft 1.1.6) all eight pass; crew-guest fetches its payload
about 2 s after `vm.start`, which is answered in about 170 ms.

## What a box needs (the Ignition)

- **Users:** `_crewagent` (the agent; its group owns the socket), and
  nothing for VMs: their uids and gids are 200000 + lease, with no
  passwd entries. The range 200001 to 216383 must be reserved: no user,
  group or subordinate id range in it, or crew-vmctl refuses the leases
  that collide.
- **Directories:** `/srv/crew` root's 0755, `/srv/crew/jail` root's 0755
  (crew-vmctl makes it if it's missing, and refuses one anyone else can
  write); `/srv/crew/root/<version>/{bin,etc}` and the `root/current`
  link, root's, from the release; `agent/`, `vms/`, `images/` the
  agent's.
- **Units:** the four in `etc/systemd/`, enabled: `crew-net.service`,
  `crew-vmctl.socket`, `crew-net-site4.timer`.
- **crew-agent.service:** `ReadWritePaths=` gets `/srv/crew/jail` as well
  as §10.8's three, so the agent can truncate the console files it owns
  there (the directories stay root's), and `After=crew-net.service
  crew-vmctl.socket`.
- **Kernel and tools:** `/dev/kvm`, `/dev/net/tun`, cgroup v2,
  `nf_tables` with `nft_compat` and `xt_connlimit`, `nft`,
  `iptables-nft`, `ip`, systemd 252 or newer, XFS with reflink at
  `/srv/crew`, `net.ipv4.ip_forward=1`, openat2 (Linux 5.6).
