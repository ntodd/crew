# crew-vz

The vz driver's macOS helper (spec §11.4, §14.3). One binary, two jobs:

- **`crew-vz daemon`** is crew-vzd, the LaunchDaemon the agent talks to. It
  starts and stops VMs, and owns every VM's helper process.
- **`crew-vz run`** is the per-VM helper. It runs one VM under
  Virtualization.framework, along with the VM's userspace network (gVisor
  netstack), console capture, control socket and exit record.

The agent (Elixir) writes `vz.json` and talks to the daemon's socket. This
file is the contract between them.

## Build

```sh
cd native
make            # builds crew-vz/bin/crew-vz and ad-hoc signs it
make test vet   # unit tests (no VM needed)
make guest      # integration-test guest, via Docker, into ../tmp/crew-vz-guest
make integration
```

- Go 1.24.5 (`mise.toml`). Every module is vendored in `native/vendor/`,
  and builds run with `GOFLAGS=-mod=vendor GOPROXY=off`. `make vendor`
  refreshes it.
- VZ refuses unsigned binaries. `make` runs
  `codesign --force -s - --entitlements entitlements.plist crew-vz/bin/crew-vz`,
  which grants `com.apple.security.virtualization`.
- Pinned dependencies: `github.com/Code-Hex/vz/v3` v3.7.1 (v3.8 needs Go
  1.25) and gVisor's `go` branch at `ace9117eb232` (2026-01-08). That's the
  last go-branch commit whose go.mod allows Go 1.24.

## Files in `<data>/vms/<vm_id>/`

| File | Written by | Notes |
|---|---|---|
| `vz.json` | agent | The VM's config (below). |
| the disk (e.g. `rootfs.ext4`) | agent | An APFS clone (`clonefile`). Must have exactly one hard link. |
| `guest.sock` | agent | The guest API for this VM (§13.4). crew-vz connects to it for every guest connection to `10.199.0.1:7777`. |
| `vz.pid` | crew-vz | Created exclusively at launch (holds the pid) and never removed. If it exists, the VM was launched once and is never launched again, even when the helper died before it could write `vz-exited.json`. |
| `console.log` | crew-vz | The guest console, capped at 8 MiB: past that it keeps the first 4 MiB, a marker line, and a rolling tail. The tail is rewritten at most once a second. A fresh file each start: whatever was at the path (a symlink or hard link included) is replaced, never written through. `vz.log` likewise. |
| `ctl.sock` | crew-vz | The helper's control socket (0660), removed on a clean exit. |
| `vz-exited.json` | crew-vz (or crew-vzd) | Written once, atomically, when the helper is done. Never overwritten. |
| `vz.log` | crew-vzd | The helper's stderr (structured logs). |

**Permissions.** The helper runs as `_crewvm` and creates files in this
directory, so the directory must be writable by `_crewvm`: 0770 with group
`crewvm`, not the 0750 of §11.2. The disk clone must be group-writable
(0660), and `guest.sock` 0660 `_crewagent:crewvm`.

**Path lengths.** macOS caps Unix socket paths at 104 bytes. Validation
rejects `guest_socket` and `ctl_socket` paths longer than 103.

## vz.json

```json
{
  "vm_id": "01JC9Z4V8R2Q",
  "vcpus": 4,
  "memory_mib": 8192,
  "kernel": "/Library/Application Support/Crew/images/<image>/Image",
  "cmdline": "console=hvc0 panic=1 quiet loglevel=4 root=/dev/vda rw rootfstype=ext4 ip=10.200.0.2::10.200.0.1:255.255.255.252::eth0:off crew.vm=01JC9Z4V8R2Q crew.token=... crew.api=http://10.199.0.1:7777",
  "disk": "/Library/Application Support/Crew/vms/01JC9Z4V8R2Q/rootfs.ext4",
  "console_log": "/Library/Application Support/Crew/vms/01JC9Z4V8R2Q/console.log",
  "guest_socket": "/Library/Application Support/Crew/vms/01JC9Z4V8R2Q/guest.sock",
  "ctl_socket": "/Library/Application Support/Crew/vms/01JC9Z4V8R2Q/ctl.sock",
  "exited_path": "/Library/Application Support/Crew/vms/01JC9Z4V8R2Q/vz-exited.json",
  "lease": {"gateway": "10.200.0.1/30", "guest": "10.200.0.2/30", "mac": "02:00:0a:c8:00:02"},
  "service_ip": "10.199.0.1",
  "cache_addr": "192.168.64.3",
  "dns_fallback": "",
  "site4": ["203.0.113.7/32", "192.168.1.0/24"],
  "max_conns": 2048,
  "mtu": 1500
}
```

Unknown fields are rejected, and vz.json itself must not be a symlink.
crew-vzd and the helper both validate the file. Fields:

| Field | Type | Rules |
|---|---|---|
| `vm_id` | string | `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. Must equal the directory name (`vms/<vm_id>/vz.json`). |
| `vcpus` | int | Between VZ's minimum and the daemon's `--max-vcpus` (default: the Mac's physical cores, capped by VZ). |
| `memory_mib` | int | Between VZ's minimum and `--max-memory-mib` (default: the Mac's memory less 2 GiB, capped by VZ). |
| `kernel` | path | Under the data dir. A regular file that is an **uncompressed arm64 `Image`** (checked by its `ARM\x64` magic). No initrd. |
| `cmdline` | string | Passed through verbatim (§13.3). Printable ASCII, 1 to 2047 bytes. Use `console=hvc0`. |
| `disk` | path | In the VM's directory. An existing regular file with one link. Attached read-write as virtio-blk (`/dev/vda`), with host syncs off (the disk is throwaway). |
| `console_log` | path | In the VM's directory. May be absent; if present, a regular file. |
| `guest_socket` | path | In the VM's directory. May be absent (guest connections to :7777 are then refused); if present, a socket. ≤ 103 bytes. |
| `ctl_socket` | path | In the VM's directory. ≤ 103 bytes. |
| `exited_path` | path | In the VM's directory, named `vz-exited.json` (fixed, so crew-vzd finds it without vz.json, and it never collides with the agent's own `exited.json`). Must be absent when the VM starts. |
| `lease.gateway` | CIDR | `<base+1>/30`: the helper's address. |
| `lease.guest` | CIDR | `<base+2>/30`: the guest's address, in the same /30. |
| `lease.mac` | MAC | The guest NIC's MAC. Unicast, and not the gateway MAC `02:c7:e0:00:00:01`. |
| `service_ip` | IPv4 | Default `10.199.0.1`. Not inside the lease. |
| `cache_addr` | IPv4 | Optional. The cache VM (`hostvm/cachevm.ip`), with no port. Unicast, not loopback. |
| `dns_fallback` | `ip[:port]` | Optional, for development: the upstream for port 53 **only when `cache_addr` is empty**. Port defaults to 53. Unicast, not loopback. |
| `site4` | [CIDR] | This site's own addresses (≤ 1024 entries; a bare address means /32). Refused like `blocked4`. |
| `max_conns` | int | 1 to 2048, default 2048 (the agent sends 1024). Open TCP connections plus UDP flows. Each TCP connection can hold up to 1 MiB each way in the helper, outside the guest's memory, so the cap bounds that: 2 GiB at 1024. |
| `mtu` | int | 1500 to 65535, default 1500. The guest's virtio-net picks it up with no guest change (measured below). |

All paths are absolute and clean, with no `..`. No component below the
data dir may be a symlink. Per-VM files must sit directly in
`<data>/vms/<vm_id>/`, so one VM's config can't point at another VM's
files. No two per-VM fields may name the same file.

## The daemon: `crew-vz daemon`

```
crew-vz daemon [--socket "/Library/Application Support/Crew/vzd.sock"]
               [--data-dir "/Library/Application Support/Crew"]
               [--max-vcpus N] [--max-memory-mib N]
               [--sandbox native/crew-vz/sandbox.sb] [--socket-group GID] [-v]
```

- The socket is created 0660 (optionally chgrp'd with `--socket-group`).
  A stale socket is replaced; a live one is an error.
- **Helpers outlive the agent and the daemon.** Each helper is started in
  its own session (`setsid`), with stdout and stderr going to
  `vms/<id>/vz.log`, never a pipe. When the daemon exits (SIGTERM or
  SIGKILL), its helpers keep running.
- **Re-adoption.** On start, the daemon asks every `vms/*/ctl.sock` for
  `status` and adopts the helpers that answer. It watches adopted helpers by
  pid. At start it also finds launches (`vz.pid`) with no helper and no
  record, from a power loss or a helper that died while crew-vzd was
  down, and records them as `helper_died`; a live but silent helper is
  watched by pid. A helper that disappears without writing `vz-exited.json` gets
  `{"code":1,"reason":"helper_died"}` from the daemon.
- The LaunchDaemon plist should also set `AbandonProcessGroup` to `true`.

### Protocol

JSON lines over the Unix socket: one object per line, one response per
request, any number of requests per connection. Lines are at most 64 KiB.
Unknown fields are rejected.

Request: `{"op": "...", "vm_id": "...", "force": bool, "deadline": unix_seconds}`

Response: `{"ok": true, ...}` or `{"ok": false, "error": "<code>", "detail": "<text>"}`

| Op | Request | OK response |
|---|---|---|
| `start` | `vm_id`, `deadline` (unix seconds, in the future and at most 72 h away) | `vm`: the helper's status, `state` `"running"`. Returns once the VM is running (≈ 130 ms) or has failed. |
| `stop` | `vm_id`, `force` | Graceful (`force` false): returns once the power button is pressed (VZ `requestStop`); the helper exits when the guest powers off. Force: returns after the helper has exited, with `vm.state` `"exited"` and `vm.exited`. If the helper hasn't exited within 5 s, crew-vzd SIGKILLs it and records `{"code":2,"reason":"killed"}`. Stopping an exited VM returns its record. |
| `status` | `vm_id` | `vm` (below) |
| `list` | none | `vms`: the running VMs. Omitted when there are none. |

`vm` objects (`state` is one of `starting`, `running`, `stopping`,
`stopped`, `error`, `unresponsive`, `exited`, `not_started`, `lost`):

```json
{"vm_id": "01JC9Z4V8R2Q", "state": "running", "pid": 4242,
 "started_at": "2026-11-03T21:01:02.123Z", "uptime_s": 12.5, "deadline": 1793740000,
 "console_bytes": 18233,
 "net": {"conns_open": 3, "conns_refused_cap": 0, "policy_refused": 7, "dial_failed": 0,
         "frames_in": 1200, "frames_out": 1150, "frames_out_lost": 0,
         "drops": {"ipv6": 9, "arp": 3}}}
```

- `exited`: the VM's helper is gone; `exited` holds `vz-exited.json`.
- `not_started`: the VM dir exists but was never launched.
- `lost`: launched (`vz.pid` exists), but there is no helper and no record
  yet. This is transient: the daemon writes the record when it notices.
- `unresponsive`: the helper process is alive but its ctl.sock isn't
  answering.

Error codes: `bad_request`, `unknown_op`, `not_found`, `invalid_config`,
`already_running`, `already_exited` (vz-exited.json exists, so the disk has
been used), `already_launched` (vz.pid exists), `start_failed` (the detail
carries the helper's exit record), `not_running`, `cannot_request_stop`,
`busy` (`restart` while VMs run, or `start` once a restart is under way),
`internal`.

**Updates** (spec §20.2). launchd runs crew-vzd as
`<data>/agent/current/bin/crew-vz`, the agent's release, which the agent
updates. crew-vzd resolves that path (and `--sandbox`'s) when it starts,
so it keeps launching helpers from the release it started from after the
agent moves `current`. The agent then asks it to restart once no VM runs:

| Op | Request | OK response |
|---|---|---|
| `version` | none | `version`: this build's (`-X main.version`) |
| `restart` | none | Refused (`busy`) while any VM is running or starting. Otherwise it answers, refuses any `start` after, and exits; launchd (`KeepAlive`) starts the new release's. |

## The helper: `crew-vz run`

```
crew-vz run --config <data>/vms/<id>/vz.json --deadline <unix> [--data-dir DIR] [--sandbox PROFILE] [-v]
```

crew-vzd runs this; it can also be run by hand. The helper:

1. Loads and validates vz.json. On failure it exits 1 **without** writing
   `vz-exited.json`, because the paths can't be trusted.
2. Refuses to start (exit 1, nothing written) if `vz-exited.json` or `vz.pid`
   exists, then creates `vz.pid`. From here on, every exit writes
   `vz-exited.json`.
3. If the deadline has already passed, it writes `{3, "deadline"}` without
   booting.
4. Builds the VM: `VZLinuxBootLoader` (Image, cmdline, no initrd), vcpus and
   memory, virtio-blk on the disk, virtio-rng, a virtio console port to the
   capped `console.log`, and a virtio NIC on
   `VZFileHandleNetworkDeviceAttachment` over a `SOCK_DGRAM` socketpair (with
   the lease MAC and `mtu`).
5. Serves `ctl.sock` and starts the VM.
6. Stops the VM at `--deadline`, on `stop`, and on SIGTERM, SIGINT or SIGHUP.

`ctl.sock` speaks the same JSON lines: `{"op":"status"}` and
`{"op":"stop","force":bool}`. Graceful is VZ `requestStop` (the power
button); force is VZ `stop`.

**Exit codes and `vz-exited.json`:** `{"code", "reason", "at", "detail"?}`, with
`at` in RFC 3339 UTC with milliseconds.

| Code | Reason | When |
|---|---|---|
| 0 | `guest_stopped` | The guest powered off (`detail: "stop requested"` after a graceful stop). VZ can't tell a guest reboot or a `panic=1` reboot from a power-off, so those are also 0. |
| 1 | `error` | VZ configuration or start failed, or the VM entered the error state. |
| 2 | `killed` | `stop force` (`"stop force"`), a signal (`"signal"`), or SIGKILL by crew-vzd. |
| 3 | `deadline` | `--deadline` reached. |
| 1 | `helper_died` | Written by crew-vzd for a helper that vanished without a record. |

**Graceful stop needs the guest's help.** On arm64, VZ's `requestStop`
arrives as `KEY_POWER` from gpio-keys on a PL061 GPIO. The guest kernel
needs `CONFIG_GPIO_PL061`, `CONFIG_KEYBOARD_GPIO` and `CONFIG_INPUT_EVDEV`,
and something in the guest must act on the key (systemd-logind does by
default). See `testdata/kernel.config`.

## The network (§14.3): the isolation boundary

The guest's NIC is one end of a datagram socketpair (one ethernet frame per
datagram). The helper owns the other end:

- **Layer 2** (`netstack/frame.go`) sees every frame first. The guest has
  exactly one neighbour, the gateway (MAC `02:c7:e0:00:00:01`). ARP is
  answered only for requests from the lease address for the gateway. Every
  other frame is dropped and counted (`net.drops` in status): IPv6, VLAN and
  other ethertypes, IPv4 not addressed to the gateway MAC, a source other
  than the lease's guest address, broadcast or multicast, and protocols
  other than TCP, UDP and ICMP echo. ICMP echo to `service_ip` (and to the
  gateway, as on Firecracker) is answered there at ≤ 10/s. Echo is never
  forwarded, and other ICMP is dropped. gVisor never sees ARP, IPv6 or ICMP.
- **TCP and UDP** go into gVisor's netstack, which runs promiscuous. Its
  forwarders hand each new flow to `netpolicy.Route`:

| Destination | Result |
|---|---|
| `service_ip:7777` TCP | Raw bytes to `guest_socket` (that socket identifies the VM) |
| `service_ip:53` UDP and TCP | `cache_addr:53`, or `dns_fallback` if there's no cache |
| `service_ip:80`, `:443` TCP | `cache_addr` on the same port |
| `service_ip`, any other port | Refused |
| In `blocked4` (§14.2's list) or `site4` | Refused |
| Anything else | Dialled by the helper as the Mac (`tcp4`/`udp4`) |

- **Refusals** are a TCP RST, or ICMP port unreachable for UDP.
- **Checked on the dialled address.** Every dial re-checks policy in
  `net.Dialer.Control`, on the socket address actually being connected:
  direct dials against `blocked4` and `site4`, and service dials against
  exactly the configured cache and fallback targets. Service dials go to
  `cache_addr` (normally in 192.168.64.0/24, which is in blocked4); that's
  the only exemption, and only on those ports.
- **The connection cap:** at most `max_conns` TCP connections plus UDP flows
  (UDP flows idle out after 60 s, or 15 s for DNS). Over the cap, flows are
  refused.
- **TCP proxying** half-closes properly (a FIN goes through as a FIN). An
  error on either side resets both.

**Measured on an M4 Max** (macOS 27.2, guest 6.18.60, 4 vCPU), single TCP
stream, guest downloading:

| Path | MTU 1500 | 9000 | 65535 |
|---|---|---|---|
| guest → 10.199.0.1:80 → cache_addr (host TCP socket) | 5.1 Gbit/s | 17.6 Gbit/s | 30.5 Gbit/s |
| guest → 10.199.0.1:7777 → guest.sock | 3.3–3.5 Gbit/s (upload 4.0–4.4) | | |
| guest → the internet (proof.ovh.net) | 236 Mbit/s, the same as the Mac's own line rate (~220 Mbit/s) | | |

## Sandboxing (`sandbox.sb`, spike S3)

`crew-vz daemon --sandbox <profile>` runs each helper as
`sandbox-exec -f sandbox.sb -D HELPER=... -D VM_DIR=... -D KERNEL=... -D GUEST_SOCK=... -D CTL_SOCK=... crew-vz run ...`.
The parameters are resolved paths, because the sandbox matches on resolved
paths (`/tmp` is `/private/tmp`). `crew-vz run --sandbox <profile>` re-execs
itself under the same profile, for trying it by hand.

The profile is `(deny default)` plus:

- the system basics (`system.sb`);
- read the kernel;
- read and write only `VM_DIR`;
- Virtualization.framework's XPC service and its sandbox extensions;
- listen only on `CTL_SOCK`, and connect only to `GUEST_SOCK` among Unix
  sockets;
- outbound TCP and UDP to anything but the Mac itself.

SBPL can't express CIDRs, so `blocked4` stays netpolicy's job. The
profile's `localhost` deny covers the Mac's own interface addresses too.

**Result:** VZ boots and runs under it (`TestSandboxedBoot`), with the
network policy intact. A probe under the same profile could not:

- write outside `VM_DIR`;
- read another VM's files or `$HOME`;
- connect to another VM's guest.sock or `docker.sock`;
- listen anywhere but `ctl.sock`;
- reach 127.0.0.1 or the Mac's LAN address.

This was tested as the logged-in user under `sandbox-exec`, not yet as a
LaunchDaemon running as `_crewvm` after a reboot; that needs root.

## Tests

- `make test`: unit tests for config validation, policy, the L2 filter,
  console capping, vz-exited.json, the control protocol, the helper lifecycle
  (with a fake VM) and the daemon (the test binary re-execs as a fake
  helper). `netstack` also runs a second gVisor stack as a fake guest over a
  real socketpair, covering the guest API, refusals, DNS, the cap, and raw
  ARP, IPv6 and ICMP frames.
- `make guest`: builds `../tmp/crew-vz-guest/{Image,rootfs.ext4}` with
  Docker: Linux 6.18.60 from arm64 defconfig plus `testdata/kernel.config`,
  and an ext4 rootfs whose only program is `testdata/guestinit` (Go,
  static) as `/init`.
- `make integration`: build tag `integration`. It needs `CREW_VZ_BIN` and
  `CREW_VZ_GUEST`, which the Makefile sets. Optional variables:
  - `CREW_VZ_DL_URL=<url>`: also download from the internet in the guest;
  - `CREW_VZ_SANDBOX=1`: also boot under `sandbox.sb`;
  - `CREW_VZ_MTUS=1500,9000,65535`: the MTUs for the cache-path throughput
    test.

  It boots real VMs through crew-vzd and checks:
  - internet TCP and DNS work;
  - `10.0.0.1`, `192.168.1.1`, `169.254.169.254`, the gateway,
    `172.16.0.1` and `100.100.100.100` are refused (RST in < 1 s), and
    blocked UDP gets ICMP unreachable;
  - other service-address ports are refused;
  - ping works to 10.199.0.1 and not to 1.1.1.1;
  - ARP is answered only for the gateway;
  - the helper drops the guest's IPv6;
  - bytes reach guest.sock;
  - the power button, force stop, the deadline (also with crew-vzd
    killed), re-adoption after a SIGKILLed daemon, and refusal to relaunch;
  - a 40 MiB console flood leaves exactly 8 MiB.

  Measured boot: `start` returns in ~130 ms, the guest API hears from
  `/init` ~210 ms after `start`, and the kernel reaches init at 0.08 s of
  uptime. (This is a minimal guest; the real image adds its own userspace,
  see S7.)
