# Architecture

[crew_spec.md](crew_spec.md) is the design. This file records what
building it settled: the spike results, and decisions the spec left to
the build.

## Spike results

| # | Result |
|---|---|
| S2 | Resolved before the build, by ntodd/foreman#132 (spec §24). |
| S8 | **Mirrors (Design A).** dockerd 29.9.2 with the containerd image store (`driver-type=io.containerd.snapshotter.v1`, the default for a fresh daemon) reads `/etc/docker/certs.d/<registry>/hosts.toml` for any registry, not `/etc/containerd/certs.d` (moby#47380, since 28.0). `e2e/s8/run.sh` pulls `ghcr.io/actions/actions-runner`, `docker.io/library/alpine` and `public.ecr.aws/docker/library/busybox` through crew_cache at 10.199.0.1 from a dind daemon with crew-guest's files: the first pulls are misses, the second all hits, and a repo off the allowlist (a 404 from the cache) falls back to the registry. Mirrors get `capabilities = ["pull", "resolve"]` explicitly, since without them containerd sends pushes to the first host too. |
| S10 | **Partly, on Flatcar rather than a hosted runner.** jailer `exec`s Firecracker: the unit's main PID is the VMM (systemd logs `Sent signal SIGKILL to main process … (firecracker)`), so no `PIDFile=` is needed. `--no-api` covers start, a guest power-off, a forced stop and a deadline kill. Whether GitHub-hosted Ubuntu runners have `/dev/kvm` is still open. Run on the M3's Flatcar 4757.2.3 arm64 VM (nested virtualization) by `native/crew-vmctl/kvm/run.sh`. |

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

## vz driver notes

- **crew-vz** (`native/crew-vz`, Go, vendored) is crew-vzd and the per-VM
  helper. Its README is the contract with the agent: `vz.json`, the
  daemon's JSON-lines protocol, the files in `vms/<id>/`, the exit codes
  and the network policy. Measured on an M4 Max: `start` returns in about
  130 ms and a minimal guest reaches the guest API about 100 ms later.
- **Where it differs from the spec's sketch,** and why:
  - `start` takes a `deadline`: the helper enforces it even while the
    agent and crew-vzd are down.
  - `vz.pid` is created exclusively at launch and never removed, so a VM
    whose helper died before writing its exit record still can't be
    launched again on a used disk. The exit record is `vz-exited.json`,
    apart from the agent's own `exited.json`.
  - VM directories are 0770 group `crewvm`, and the clone 0660: the helper
    (`_crewvm`) writes there.
  - The socket is `<data>/run/vzd.sock`: the data directory itself is
    root's, and `run/` is the one place `_crewvm` creates files outside
    VM directories.
  - Graceful stop is VZ's `requestStop`, the arm64 power button through
    gpio-keys: the guest kernel needs `GPIO_PL061`, `KEYBOARD_GPIO` and
    `INPUT_EVDEV`, and something that acts on the key. The agent also asks
    through the guest API's control channel, so either way works.
  - VZ can't tell a guest power-off from a reboot or a panic, so all exit
    0 (`guest_stopped`).
- **`site4` on vz** is computed when each VM starts: the Mac's connected
  IPv4 subnets, the site's egress address (from `CREW_EGRESS_ECHO_URL`,
  every 10 minutes) and `CREW_EXTRA_BLOCKED`. A running VM keeps the set
  it started with.
- **The cache VM's address** comes from `hostvm/cachevm.ip`
  (`CREW_VZ_CACHE_ADDR` overrides it). Until the cache VM exists (§12.3),
  guests need `CREW_VZ_DNS_FALLBACK` to resolve names.
- **The helper's network memory** is bounded, not budgeted: TCP buffers
  are at most 1 MiB each way per connection and the agent sends
  `max_conns` 1024, so a VM can hold at most about 2 GiB in its helper,
  outside its own memory. The 8 GiB host reserve covers one such VM; a
  per-VM aggregate budget is a known gap (security.md).
- **`firewall_ok` on vz** means crew-vzd answers. There's no host
  firewall to verify: the boundary is the helper's netstack, and its
  policy tests run against a real guest in `make integration`.
- **Tests at three levels:** Go unit tests and the real-VM suite in
  `native/`; the agent's driver against a fake crew-vzd, and `mix test
  --only vz` booting real VMs through the agent's own start path; and
  `E2E_VZ=1` in `e2e/`, a job scheduled by the control plane onto a real
  VM. The test guest's `crew` mode walks the guest API from inside the VM.
- **Development images:** with `CREW_DEV=1`, `CREW_DEV_IMAGE_DIR` makes
  `image.prepare` clone a local `Image` and `rootfs.ext4` instead of
  downloading.
- **`install-macos.sh`** (`packaging/macos/`) creates `_crewagent`,
  `_crewvm` and `crewvm`, lays out the data directory, installs the two
  LaunchDaemons and waits for enrollment. A reinstall keeps the box's
  identity, name, URL and the admin's settings in `agent/env`; an
  uninstall stops the agent first, then every job VM. `test-install.sh` checks a dry
  run's plists and env without root. Spike S3 (launchd as `_crewvm`, with
  nobody logged in, after a reboot) still needs a real install.

## Firecracker driver notes

- **crew-vmctl** (`native/crew-vmctl`, Go, standard library and the
  already-vendored `x/sys/unix`) is the root helper and crew-net. Its
  README is the contract with the agent: the verbs, the files in
  `vms/<id>/` and `jail/firecracker/<id>/`, the unit, the exit record,
  the packet filter and what a box's Ignition must install.
- **Socket-activated, as §10.8 says, not sudo:** the agent's
  `NoNewPrivileges` rules out setuid helpers. `crew-vmctl.socket` accepts
  each connection and starts one `crew-vmctl serve` for it. Its settings
  (`--data-dir`, `CREW_VM_NET`) come from its unit; it clears its
  environment and runs `ip`, `nft`, `iptables-nft-*`, `systemctl` and
  `systemd-run` with a fixed `PATH` only.
- **Nothing the agent leaves can steer root.** Files under the data
  directory are opened with `openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS)`;
  the clone must be a regular file with one link, owned by the connecting
  uid, and is hard-linked into the jail through the descriptor that was
  checked (`AT_EMPTY_PATH`). `agent/env` is parsed for `CREW_UPLINK` and
  `CREW_EXTRA_BLOCKED` only, never given to systemd as an
  `EnvironmentFile`.
- **Each VM has its own kernel,** `vms/<id>/kernel`, a reflink of the
  image's (a copy where reflinks don't work; ~50 MB), and that's what
  crew-vmctl hard-links into the jail. The image's own can't be: §12.4's
  XFS project quotas put `images/` and `vms/` + `jail/` in different
  projects, and XFS refuses hard links between projects (EXDEV). A real
  Flatcar box failed every start on it; the `:kvm` runner now sets up the
  same projects, and failed the same way before the fix.
- **`fc.json`:** the agent writes it in Firecracker's own format with host
  paths and the size's rate limiters (a bucket of one second's worth,
  refilled each second; `*_mbps` limits are Mbit/s). crew-vmctl decodes
  it against the part of the schema Crew uses, so a vsock, an initrd or
  a second drive is refused, holds every value to `vm.json` and fixed
  bounds, and writes the chroot's copy from what it checked, with chroot
  paths and its own logger (`/fc.log`, `Warning`) and metrics.
- **Where it differs from §11.3's unit, and why:**
  - the console and stderr go to `jail/firecracker/<id>/`, not
    `vms/<id>/`. systemd opens them as root and follows symlinks, and the
    agent owns `vms/`, so a compromised agent could have had the guest's
    console appended to any file. The agent owns the two files, so it
    still caps the console, and `crew-agent.service` needs
    `/srv/crew/jail` in `ReadWritePaths` for that (the directories stay
    root's). `cleanup` moves them into `vms/<id>/`.
  - `ExecStopPost` runs `crew-vmctl exited`, which records
    `SERVICE_RESULT`, `EXIT_CODE` and `EXIT_STATUS` before `--collect`
    drops the unit. That's how a deadline kill (`timeout`) is told from a
    power-off or a crash after the agent was down.
  - a forced stop is `systemctl kill --kill-whom=main --signal=SIGKILL`.
    Killing the whole unit goes through `cgroup.kill`, which on a real
    host also killed the `ExecStopPost` forked into the cgroup a moment
    later, and the exit record with it.
- **The packet filter** differs from §14.2's text in three places:
  - **pings are accepted to `10.199.0.1` only.** §14.2's
    `iifname "crewt*" icmp type { echo-request } … accept` takes an echo
    request to any local address, so a guest could ping its gateway,
    other taps' gateways and the host's uplink and tailnet addresses: the
    input chain, which `blocked4` and `site4` in forward don't cover. The
    spec's text has the same mistake;
  - `blocked4` leaves out `255.255.255.255/32` (inside `240.0.0.0/4`; nft
    refuses overlapping intervals, so the spec's set doesn't load);
  - the 2048-connection cap is in iptables-nft's mangle table
    (`etc/connlimit.rules`, `xt_connlimit`) because Flatcar's kernel has
    no `nft_connlimit` for `ct count`. Both use `nf_conncount`.
- **`nft-verify`** compares the box's listings with the same files loaded
  into a fresh network namespace by the same binaries, not with a stored
  hash: nft 1.0.6 and 1.1.6 print the same table in different orders,
  so a hash would break on a Flatcar update. crew-vmctl embeds the files,
  so what crew-net loads and what's verified are one copy.
- **crew-net is crew-vmctl:** `net-up` at boot (crew0, the filter loaded
  once, pairs for taps that exist, site4), `site4` every 10 minutes. The
  egress address reaches it as `agent/egress4`, which `CrewAgent.Site`
  writes on Firecracker boxes.
- **A cleanup that fails isn't forgotten** (`CrewAgent.VMs.Cleanup`).
  `driver.cleanup/1` may now return an error (the behaviour's spec said
  `:ok` only). When it does, `vm.exited` says `cleanup: "error"`,
  `vms/<id>/cleanup-pending` records it, and the VM keeps its lease (its
  tap may still be there) and its clone (the jail's hard link keeps the
  space anyway, and the disk watchdog sees it); its directory isn't
  swept. A start whose cleanup fails keeps its directory the same way,
  with an exit record. `CrewAgent.VMs.Janitor`, which replaced the
  adoption task, takes every lease the agent's records hold (live VMs,
  pending cleanups) in its `init`, so before the link starts and any
  `vm.start` can come; adoption follows asynchronously. A lease two
  records hold is a conflict that refuses every `vm.start`
  (`lease_conflict`) until it's sorted out. Every minute it retakes the
  leases, retries pending cleanups and cleans up whatever crew-vmctl
  holds (`list`: units, and jails with the lease each recorded) for VMs
  with no live or pending record here, holding each such orphan's lease
  until its cleanup works; the jail is the record, so a failed cleanup
  or a failed `list` is simply tried again.
- **A lease is one jail's,** on crew-vmctl's side too: `tap-add` refuses
  a lease any VM's jail records (`lease_in_use`), and `cleanup` leaves a
  pair and tap another jail records, so a mistake in the agent's
  bookkeeping can't give one VM's tap to another or delete it.
- **When the filter stops verifying:** crew-vmctl's `start` checks it
  itself (about 50 ms a start on the M3's VM), and the agent kills every
  VM on the box when crew-vmctl says it doesn't verify twice in a row
  (`killed_stop`, detail `firewall_not_verified`), and starts nothing
  until it does. An unreachable crew-vmctl or an egress address not yet
  learned holds starts back without killing anything.
- **site4 is built from root's side only,** so a compromised agent can
  add to it but never weaken it. Egress addresses are add-only: each
  refill adds the agent's `agent/egress4`, if it's new, to crew-vmctl's
  list in `/srv/crew/vmctl/egress4` (root's, at most 64, never trimmed
  by anything the agent writes; full means no more are added), and every
  address in the list goes into site4. `CREW_EXTRA_BLOCKED` and
  `CREW_UPLINK` come from `/etc/crew-box/extra-blocked` and
  `/etc/crew-box/uplink`, which the Ignition writes, not from the
  agent's env; crew-vmctl doesn't read `agent/env` at all. `nft-verify`
  checks site4 against the same inputs. The agent asks for a refill the
  moment it learns a new address. With an echo service configured no VM
  starts until site4 holds the agent's address; without one the
  capabilities carry `no_egress_echo`.
- **VM ids are checked:** crew-vmctl refuses a lease whose uid or gid
  (200000 + the lease) is in `/etc/passwd`, `/etc/group`, Flatcar's
  `/usr/share/baselayout` copies, or an `/etc/subuid`/`/etc/subgid`
  range.
- **`alive?` and `stats`** read the unit's cgroup
  (`/sys/fs/cgroup/system.slice/crew-vm-<id>.service`): alive while it
  exists, which is until systemd is done with the unit, exit record
  included; CPU from `cpu.stat` deltas, memory from `memory.current`.
  Neither needs a root call.
- **The console cap** runs in the agent every second: past 8 MiB the file
  keeps its first 4 MiB, a fixed-width marker counting what was dropped
  and a rolling last 4 MiB, rewritten in place (systemd appends with
  `O_APPEND`). Output written between reading the tail and truncating is
  lost.
- **arm64 guests boot with `console=ttyS0`,** not §13.3's `ttyAMA0`:
  Firecracker's serial port is an 8250 UART on arm64 too, and with
  `ttyAMA0` the kernel found no console for init. Firecracker adds
  `pci=off` itself on arm64, which the kernel doesn't know there.
- **Requirements** are reported as features (`kvm`, `tun`, `cgroup2`,
  `xfs_reflink`, `systemd` for 252 or newer, plus `rate_limits`);
  `firewall_ok` is the last `nft-verify`, at start and every 60 s. When
  the verdict changes, either way, the reporter sends `box.capabilities`
  at once rather than at its next minute: a box that joined while the
  egress address was still being learned showed "Firewall not verified"
  for up to a minute after it was.
  `driver_version` is Firecracker's and crew-vmctl's, from crew-vmctl's
  `info` verb, which also gives systemd's version.
- **`box.restart`** goes through `crew-vmctl reboot` on Firecracker
  boxes, and `box.reboot` reports `can_restart: true` there.
- **Firecracker 1.17.0** is pinned in `native/crew-vmctl/firecracker.env`
  by its release tarballs' SHA-256s (the newest release; 6.18 guests
  need 1.16.1 or newer).
- **Measured** on the M3's Flatcar VM (arm64, nested): crew-guest fetches
  its payload about 1.9 s after `vm.start`; a forced stop's `vm.exited`
  comes about 1.2 s after `vm.stop`, mostly the agent's 1 s poll.
- **What root runs comes from `root/current/bin`,** not §11.3's
  `agent/current/bin`: the agent can write `/srv/crew/agent` (it updates
  itself there, §20.2), so a compromised agent could have replaced
  crew-vmctl, jailer or Firecracker. The box's Ignition installs a
  release's root-run files into a root-owned `/srv/crew/root/<version>`
  with a `current` link, and refuses units that name `agent/`; the
  units, crew-vmctl's paths (a constant, not a setting) and a test say
  `root/current/bin`. How an agent update reaches `root/` is the
  updater's (§20.2), still to build.
- **Not yet tested on a real VM:** a graceful stop through the guest API
  (the guest image needs a JIT config it accepts, or a test mode like
  crew-vz's guest), the network matrix of conformance items 4 and 5
  beyond `vm_pairs` failing closed, and the console cap against a guest
  that floods its console.

## Live log notes

- **One stream process per VM** (`Crew.Logs.Stream`) stores its batches in
  `seq` order; the control plane numbers the lines itself, so `n` carries
  on across epochs and lost-line markers. Its place (epoch, seq, n) is on
  the VM's row, so a restarted stream picks up where it was.
- **Acks and resends are notifications**: the agent handles them at once
  and sends no `op.result`, and the control plane sends them without an
  operation row. Every other command is an operation.
- **Each log keeps an index** (`index.json`: step starts, groups,
  annotations), saved with each ack. The job page gets it with the page,
  and again whenever it's saved; the viewer also learns from the lines
  pushed to it, and merges the two.
- **GitHub's log** is fetched through its redirect with no token on the
  second request, capped at `CREW_LOG_LIMIT_BYTES`, and split into steps
  by timestamp against the API's steps (`step-<number>`).
- **The viewer** (`assets/js/log_viewer.js`) keeps its logic in
  `log_core.js` (ANSI, folding, the index, links), tested with `node
  --test`. Groups fold in finished steps; while a job runs, a group whose
  step isn't known to be finished stays open.
- **While someone has a running job's page open,** its steps come from
  the API every 10 s (rate-limited per job, however many are watching),
  as an optional call.

## crew-guest notes

- **SIGTERM** is how a graceful stop (`requestStop`, the power button,
  ctrl-alt-del) reaches crew-guest. The BEAM's own handler calls
  `init:stop`, which stopped the release without stopping the runner or
  reporting anything. While crew-guest waited for its payload it also sat
  out the supervisor's 5 s shutdown timeout: the boot ran in `Main`'s
  `handle_continue`, so `Main`, which traps exits, never saw the shutdown.
  That was the 5.3 s measured below.
- **crew-guest now replaces that handler** on `erl_signal_server`
  (`CrewGuest.Signals`), and the boot and the final flush run in tasks, so
  `Main` acts on a stop in every phase. SIGTERM takes the agent's stop
  path, then exits rather than powering off, since systemd is already
  powering off.
- **One SIGTERM to the runner, from crew-guest.** The unit is
  `KillMode=mixed`. With the default, systemd signalled the whole cgroup
  and crew-guest signalled run.sh again. Under `RUNNER_MANUALLY_TRAP_SIG`
  run.sh runs the listener in its own process group, forwards the first
  signal to it as SIGINT, drops its trap and waits for the last output;
  the second SIGTERM killed it in that wait. `Runner.stop/1` signals once
  per runner, whichever stop asks first. systemd's SIGKILL still clears
  the cgroup when crew-guest exits, or at the timeout.
- **The budget:** 11 s from SIGTERM (10 s for the agent's stop, as §13.5
  says). The runner gets all but the last 2 s: its own cancel gives a
  step 7.5 s after SIGINT before it escalates (`ProcessInvoker`), so 9 s
  covers that plus time for the worker to report. A runner still up then
  is SIGKILLed with every process group in its tree (run.sh's and the
  listener's, never crew-guest's), gets 0.5 s for its output to close,
  and is reported `job_finished` with detail `runner_stop_timeout`; then
  the final snapshot and the flush, in the 2 s left. A step that ignores
  SIGTERM too, which the runner would kill at 10 s, is killed at 9 s.
- **Past the budget:** `-shutdown_time 2000` caps `init:stop`, and the
  handler halts the BEAM 12.5 s after SIGTERM. Its timer lives in
  `erl_signal_server`, which Kernel stops late in `init:stop`, so the cap
  covers what the timer can't. All of it is under the unit's 15 s
  `TimeoutStopSec`. A test holds the unit, `vm.args` and the defaults to
  these bounds.
- **A Port reports its exit only once its output closes,** so with
  run.sh's listener still holding the pipe, crew-guest doesn't see an
  exit until the listener is done or killed.
- **In local mode** a real SIGTERM ends crew-guest in about 30 ms while it
  waits for its payload, and in about 0.5 s mid-job, most of it the steps
  lane's 2-a-second limit on the last snapshot.

## Guest image notes

- **The build** is `images/guest` (`make -C images/guest`). Every step
  runs in Docker on a builder image: ubuntu:24.04 by digest, with
  packages from the guest's own snapshot, so the toolchain (gcc,
  e2fsprogs, zstd) is pinned too. The manifest tools are
  `images/guest/tools`, a Mix project over `crew_protocol`.
- **Every pin** is in `versions.env` (kernel, moby's check script, apt
  key fingerprints, the runner, Playwright, the Elixir build image) or
  `packages.lock` (the base digest, the snapshot timestamp and every
  installed package per arch, the base image's and the third-party
  repos' included). The lock drives apt (a pin per package) and the
  build fails unless `dpkg-query` matches it exactly. PGDG's archive repo
  is configured at low priority so a pinned client still installs after
  PGDG drops it from the main repo.
- **The kernel config** is a fragment, `kernel/arm64.fragment`, over the
  pinned version's defconfig; the full result is committed as
  `kernel/arm64.config`, and the build refuses one that olddefconfig
  would change. Whatever boot, Docker and the Crew list need is built in
  (the check reads the Crew list's "present" as `=y`); defconfig's other
  modules ship in `/usr/lib/modules`. Since 6.15 the iptables tables
  need `NETFILTER_XTABLES_LEGACY`. The tarball's `.sign` must be by Greg
  Kroah-Hartman's or Linus Torvalds's key (`kernel/keys/`).
- **check-config.sh** also reports on the machine it runs on (cgroups,
  AppArmor, sysctls); only its `CONFIG_` lines under "Generally
  Necessary" count, and it runs with a `uname -r` that answers the
  config's version. It needs GNU sed, so on macOS it runs in the builder.
- **eth0 stays eth0.** 6.18 lets udev rename an interface that's up, and
  predictable naming would, leaving crew-guest's
  `net.ipv6.conf.eth0.disable_ipv6` with nothing to write. The image
  masks `99-default.link`.
- **The job-started hook** is installed as
  `/opt/crew/hooks/job-started.sh`: actions/runner picks a hook's shell
  by its extension. §13.1 and §19.5 name it without `.sh`.
- **The runner's `.env`** also sets `LANG=C.UTF-8`, `ImageOS=ubuntu24`
  (as on GitHub's runners; some setup actions read it) and
  `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright`. The cache CA's variables are
  crew-guest's to add at boot.
- **Playwright** 1.64.1's Chromium is Chrome for Testing, which does now
  build for linux-arm64. The image has Chromium, its headless shell and
  ffmpeg, laid out as `playwright install` would, owned by the runner,
  with a `.links` entry so another version's `playwright install` keeps
  them.
- **More is masked than §13.1 lists:** systemd-firstboot (every boot is
  a first boot), getty.target and console-getty, e2scrub, fstrim and
  dpkg-db-backup. The journal is volatile (64 MiB), units get 10 s to
  stop, and `/etc/.updated` is written at build time so ldconfig doesn't
  run at every boot. The finished image's apt sources are the live
  archive, as on a hosted runner; the snapshot is for the build.
- **The manifest** uses `Crew.Images.Image`'s field names. `rootfs_sha256`
  and `rootfs_size` describe the `.rootfs.ext4.zst`, what `image.prepare`'s
  `rootfs` file ref is checked against; `rootfs_ext4_*` describe the
  decompressed file. It adds `kernel_version`, `packages_lock_sha256` and
  `disable_update`. Arches are the protocol's `arm64` and `x64`, also in
  the file names (`crew-guest-<version>-arm64.*`).
- **The signature** is `CrewProtocol.Auth.sign_manifest/2`'s: ed25519 over
  `"crew-manifest-v1\n"` and the manifest's exact bytes, base64, no
  newline. CI's sign job uses `images/guest/sign.sh` (openssl only, since
  the job runs no third-party actions); a test holds it to the same
  bytes. The key is `CREW_RELEASE_SIGNING_KEY` in the `release-signing`
  environment (the base64 32-byte seed); the `CREW_RELEASE_PUBLIC_KEY`
  repository variable is its public half, as the control plane takes it.
  `images/guest/keys/test-signing.key` is a development-only test key,
  refused by `--release`.
- **Measured on the M4 Max** (Docker Desktop, 16 CPUs): the kernel builds
  in 3.5 minutes; the rootfs in 3.5 minutes with every stage rebuilt
  (2.8 of them in apt) and about 40 s warm; compression (`zstd -19
  --long=27`) takes 75 s. The image is 3.9 GiB (2.9 GiB used) and 734 MB
  compressed. `make smoke` boots it through crew-vzd: `start` returns in
  about 120 ms, crew-guest fetches the payload 0.85 s after `start`,
  Docker answers at 1.2 s of guest uptime and the runner starts at 1.23
  s. The power button powers the guest off in 0.26 s with the runner up,
  and in 5.3 s while crew-guest is still waiting for its payload.

## Image registry notes

- **Registration** is from a manifest's exact bytes and its signature,
  checked with `CREW_RELEASE_PUBLIC_KEY`; there's no unsigned path. The
  control plane registers the manifests in `CREW_IMAGE_RELEASE_DIR` (its
  image's copy of the release, §20.1) at every boot. The same manifest
  again is the same image; a different manifest under a registered
  version and arch is refused.
- **Mirroring** (`Crew.Images.Mirror`, its own Oban queue of one) uses
  the kernel and `.rootfs.ext4.zst` beside the manifest when they're
  there, else downloads them from
  `<github web>/<CREW_UPDATE_REPO>/releases/download/v<version>/`,
  streamed to `CREW_IMAGE_DIR/<id>/` and capped at the manifest's size.
  Either way each file is hashed against the manifest. Until both are
  in, the image can't be a default, so no box is sent a prepare it
  can't finish. A boot re-enqueues a mirror that never finished.
- **Boxes download** from `/images/:id/kernel|rootfs` without
  credentials, as Foreman's agents download releases: the files are a
  public release's, and the agent checks them against the signed
  manifest. `Range` resumes a download.
- **Keeping images on a box:** the plan sends `image.remove` for ready
  images past the default, the usable one, any a live VM there started
  from, and the newest other. The row reads `removing` until the next
  inventory drops it (or lists it again, and it's sent again).
- **Runner freshness:** actions/runner's releases are read daily (and at
  boot when there are none) into the settings table. "Behind" counts
  from the first release after the image's runner, not the latest.
- **With a release configured, development skips the placeholder
  images** (`0.0.0-dev`), which would otherwise be the newest
  registered and win the default.

## Image preparation notes

- **Verify before downloading.** The manifest's signature is checked
  with `CREW_RELEASE_PUBLIC_KEY`; with no key the prepare fails
  (`no_release_key`), never skipping the check. The manifest must then
  agree with the command on version, arch and the kernel's and
  compressed rootfs's SHA-256 and size (`manifest_mismatch`). An image
  that's already ready is reported ready at once.
- **Room first:** `df -Pk` on `images/` must show the kernel, the
  compressed rootfs and `rootfs_ext4_size`, plus 1 GiB (`no_space`).
- **Downloads** stream through Req into `images/.<id>.tmp/*.part`,
  hashed as they arrive and capped at the expected size: a server that
  sends more fails the prepare. Connection errors, timeouts, 408, 429,
  5xx and short bodies are retried 5 times (backoff 1 to 8 s), resuming
  with `Range: bytes=<n>-`; a 200 starts the part over. Requests to the
  control plane's own origin (`CREW_URL`'s host and port) carry the
  socket's signed `x-crew-agent-*` headers, fresh per request; other
  hosts, redirect targets included, get none.
- **Converting** streams the `.zst` through OTP's `:zstd` with
  `windowLogMax` 27 (`zstd --long=27`), hashing what comes out and
  capping it at `rootfs_ext4_size`. The 0.1.0-dev arm64 image (734 MB to
  3.8 GiB) prepares from a local server in about 5 s on the M4 Max.
- **Layout:** `kernel`, `rootfs.ext4`, `manifest.json` (the signed
  bytes) and `manifest.sig`, all 0444 and synced, then `ready`, then the
  directory is renamed to `images/<id>/`. The temporary name isn't a
  UUID, so the inventory and `ready?` never see it. A failure removes
  it; a killed prepare (`op.cancel`, an agent restart) leaves its parts
  for the next prepare to resume, checked with the rest.
- **Progress:** `image.state` goes out on each change of state
  (downloading, verifying, converting, then ready or failed with the
  error), and while working at most every 2 s as the percentage moves
  (bytes of both downloads, then compressed bytes decompressed), or
  every 30 s when it doesn't.

## Registry cache notes

- **Design A only** (spike S8): dockerd's containerd store and BuildKit
  reach the cache through per-registry mirrors, as
  `https://10.199.0.1/v2/<prefix>/<repo>/…` (`?ns=` is ignored). One
  leaf for the listen IP, no DNS interception and no SNI or `Host`
  matching; `CrewCache.CA.Certs.name_constraints/1` and the TLS options
  are where Design B would go.
- **`GET /v2/`** (and `/v2/<prefix>/`) answers 200 with
  `Docker-Distribution-API-Version: registry/2.0`, as a registry does an
  anonymous client. §15.3 passes it through, but under Design A there's
  no single upstream to pass it to, and the mirror never sees
  credentials anyway.
- **Anything the cache doesn't serve is a 404, never a pass-through.**
  The mirror only gets anonymous requests (dockerd keeps credentials
  for the real registry) and containerd goes to the upstream itself on
  any status of 400 or more. So repositories outside the allowlist,
  hosts that aren't enabled, private repositories under an allowlisted
  glob (the anonymous fetch is denied), tag lists, referrers and the
  rest get 404, and the cache can't be used as an open anonymous proxy
  to seven registries. Upstream failures are 502. No error carries a
  `WWW-Authenticate`, so containerd doesn't try to log in to the
  mirror. Writes of any kind are 405 and go nowhere.
- **Name Constraints, Design A:** the intermediate's critical extension
  permits `iPAddress` listen-IP/255.255.255.255 and excludes a `dNSName`
  of "" (RFC 5280: a DNS constraint matches any name made by adding
  labels on its left, so the empty one matches all names). Tests check
  it with `openssl verify` and Go's crypto/x509, and Go's TLS client and
  `openssl s_client` against the running listener. Leaves have an IP SAN
  and no hostname-like CN: OpenSSL checks a CN as a DNS name when there's
  no DNS SAN, and would refuse it.
- **OTP can't verify the cache's chain.** `pubkey_cert` (OTP 29) spells
  its `iPAddress` constraint clause `ipAdress` and crashes, so an Erlang
  TLS client verifying the chain fails. Nothing in Crew needs to: guests
  verify through dockerd, containerd and BuildKit (Go).
- **The chain** is regenerated on `rotate_ca` and when the listen IP
  changes, not when enabled hosts change: under Design A the constraints
  name the IP. Leaves are replaced when a day old (checked hourly)
  through OTP's PEM cache, so the listener serves the new one at the next
  handshake. `cache/ca/root.pem` is the guests' anchor (also `GET
  /ca.pem`).
- **Every upstream connection is dialled through `CrewCache.Dial`,** a
  `gen_tcp` `tcp_module`: names resolve over `CREW_DNS_UPSTREAMS` (A
  records only; the cache dials IPv4 only) and blocked4 and site4
  answers are dropped, for upstreams, token realms and redirect targets
  alike. Finch's per-host pools and Mint's TLS verification work
  unchanged above it. Redirects are followed to https only, without the
  token once the origin changes. Tokens come from the compiled realm;
  the challenge's realm is ignored, its `service` used.
- **site4** in the cache is its own connected subnets (every 10
  minutes), `CREW_EXTRA_BLOCKED`, and a `site4` list the agent can push
  in `POST /config` (the egress address it learns), alone if it likes:
  the other settings stay as they are. A new policy applies at once:
  lookups and dials read it, cached DNS answers are dropped, and when it
  refuses more the upstream pool restarts, so no open connection to a
  newly refused address is reused (fetches in flight on it fail and
  their clients retry).
- **Tags:** a HEAD or GET by tag asks the upstream (HEAD, with the
  client's `Accept`), then fetches and stores the manifest if it's new,
  so the GET by digest that follows is a hit. An upstream HEAD without
  `Docker-Content-Digest` is a 404. The micro-cache key normalises
  `Accept` to its types without parameters, sorted.
- **Coalescing:** one fetch per kind and digest. It runs in its own
  process into a temporary file in the store, so it finishes if its
  clients leave; clients tail the file, through a shared counter and a
  single wake-up when they've caught up, so a slow reader never piles up
  messages. The last byte is held back until the SHA-256 matches, so a
  mismatch never completes a response: clients already streaming are cut
  short, and for 30 s after, requests for that digest get 502 without
  asking the upstream again. Other failures end the fetch at once.
  Manifests (at most 4 MiB) are verified before they're served, and
  stored with their own `mediaType` when they have one; bytes first
  stored through `/blobs/` become a manifest when fetched as one.
- **Space and load:** every download reserves space in the store before
  it writes, held by its fetch until it commits or fails, so downloads
  in flight count against the quota: the whole length when there's a
  `Content-Length`, otherwise 8 MiB ahead of what's written. One that
  can't reserve at the start is a 404 (containerd goes upstream); one
  that can't later is cut short. One object may take at most half the
  quota. At most 512 fetches run at
  once (`max_fetches`); past that a miss is a 503. Files are synced
  before the rename that commits them; at start, rows whose file is
  missing or the wrong size are dropped, files no row knows are removed,
  and temporary files older than an hour are swept every 10 minutes.
  The directory isn't fsynced after the rename (OTP can't open one): a
  power cut can lose the newest objects, which the start-up check drops.
- **The store** keeps each object once, under the host and repository
  that first fetched it: a purge by repository removes those, and
  another repository sharing one fetches it again. `Range` is served for
  stored blobs only; a miss is served whole (containerd skips to its
  offset). Touches are written in batches every 2 s. `CREW_CACHE_MAX_GIB`
  defaults to a quarter of the disk holding the cache directory, from
  `df` at start.
- **Counters** (`GET /stats`) run from the cache's start, and
  `instance`, a random id made at each start and never saved, names the
  run: the agent keeps its delta baseline across its own restarts and
  resets it when `instance` changes. A hit is an object served from the
  store, a miss one fetched; a tag request counts as its manifest. `bytes_stored` is what the store holds now, per host;
  `top` is the 10 repositories that served the most bytes. Per-host
  `mismatches` are there for `cache_stats`.
- **Management** updates are partial (what isn't sent is unchanged) and
  unknown fields are refused; `POST /purge` takes `cache.purge`'s scope
  strings. A token, when set, guards every endpoint.
- **DNS:** each client gets 100 queries a second (a token bucket): over
  it, UDP queries are dropped without a reply or a task, and TCP ones
  answered REFUSED. A client has at most 16 TCP connections, all clients
  256. REFUSED for `ANY`/`AXFR`/`IXFR`, the private suffixes and the
  names themselves, reverse zones that overlap blocked4 or site4
  (`10.in-addr.arpa` too),
  IPv6 reverse lookups in loopback, link-local, ULA and mapped space, and
  malformed reverse names. Stripped from every section: A records in
  blocked4 or site4, AAAA records that are loopback, link-local, ULA or
  a mapped form of a refused IPv4 address, and SVCB/HTTPS records, whose
  address hints would carry what the A records can't. TTLs are capped at
  300 s in the answer as in the cache. Over UDP an answer is cut to the
  client's EDNS size (512 without) and marked truncated.
- **The parent (box side):** by-digest fetches ask the parent first, and
  fall back to the upstream within the same fetch if it can't be
  reached, answers anything but 2xx, or takes over 5 s to the first byte.
  A parent that fails after it started sending, or sends wrong bytes,
  cuts that fetch short and is skipped for the digest for 10 minutes. It
  is the one connection outside the address policy: it lives on the
  tailnet (in blocked4) and resolves the system's way, pinned by its CA
  and token. Parent serving mode and `parent_tokens` aren't built;
  `CREW_CACHE_MODE=parent` refuses to start.
- **Tests** run a fake registry and storage host over TLS in-process,
  with names resolved from a fixed map and loopback the only address the
  policy lets through. Those settings (`net_except`, `resolve`,
  `origins`, `upstream_cacerts`) have no environment variables, and
  `net_except` can only ever open loopback.

## Cache integration notes

- **The CA generation** a box's cache is on counts only once its
  `cache.config` with `rotate_ca` succeeds: the generation rides in the
  operation's args, and `Crew.Caches.config_applied/1` reads it from the
  `op.result`. A rotation that failed, or never answered, is asked for
  again at the next join.
- **site4 reaches the cache on its own**, every 60 s when it changed
  (the egress address is learned after the agent starts, and can move),
  and again after a push that failed, as `POST /config {"site4": …}`.
- **Stats survive an agent restart:** the last `GET /stats` is kept in
  `agent/cache-stats.json` with the cache's `instance`; a new instance,
  or counters that went down, start from 0.
- **No parent from the control plane yet.** Parent serving (§15.7) isn't
  built, so `cache.config` never carries one and the agent sends no
  `parent` key: a parent given to the cache some other way stays.

## Flatcar box notes

- **No Butane.** §12.2 renders `images/flatcar/box.bu.eex`; Crew builds
  the Ignition (3.4.0) as a map in `Crew.Boxes.Flatcar`, as Foreman
  does: no binary to ship or pin, and the tests read the map. CI runs
  `ignition-validate` (pinned by digest) on `mix crew.ignition` samples
  for every box type, arch and mode.
- **One file of pins,** `images/flatcar/VERSION`: the first-boot
  Flatcar (version, image and kernel SHA-512s, verity hashes, USR-A),
  the Tailscale sysext's version and SHA-256s, and vfkit. The Ignition
  and the launchers compile it in; the launchers are served with it and
  the control plane's URL filled in, and refuse a URL sh could act on.
- **Release files,** registered from `CREW_AGENT_RELEASE_DIR` at boot
  (`Crew.Agents.Releases`): `crew-<agent|cache>-<version>-<target>.tar.gz`,
  `.sha256` (`<hex>` or `<hex>  <file>`) and `.sig`
  (`CrewProtocol.Auth.sign_release/4`, base64, over
  `release_message/3`). Both tarballs unpack at their root, without a
  top directory. A target's install set is its newest version with both.
  Boxes download from the GitHub release; with `CREW_DEV=1` and the file
  here, from `/agent/releases/:version/:target/:file`.
- **What the agent tarball must hold:** `bin/crew_agent` (an Elixir
  release, `start`), `bin/crew-vmctl`, `bin/jailer`, `bin/firecracker`,
  `etc/nft.conf`, `etc/connlimit.rules`, and crew-vmctl's five units in
  `etc/systemd/` (`native/crew-vmctl/etc/systemd`); the cache's,
  `bin/crew_cache`. The install refuses a release without any of them.
- **On the data disk:** `/srv/crew/agent/<version>/` is the agent
  tarball and `<version>/cache/` the cache's, both root's and read-only;
  `agent/current` points at the version, `agent/env` is root's 0600.
  §10.1 names `agent/releases/<version>/`; the brief for this layer put
  them directly under `agent/`. The agent and crew_cache run from there
  (`current/bin/crew_agent`, `current/cache/bin/crew_cache`), with
  `RELEASE_TMP` in their runtime directories (the release itself is
  read-only) and `RELEASE_DISTRIBUTION=none`.
- **What root runs is in `/srv/crew/root/<version>/`,** not `agent/`:
  the agent owns `agent/` (to update itself, §20.2), so it could rename
  `current` to a release of its own. `crew-agent-install` stages the
  tarballs in `root/` (root's 0755, as `/srv/crew` is), checks them, and
  copies `bin/crew-vmctl`, `bin/jailer`, `bin/firecracker`, the ruleset
  and the units there, with the units' `agent/current/bin/` rewritten to
  `root/current/bin/` (a unit still naming `agent/` refuses the
  release). `crew-root-units` copies the units into `/etc/systemd/system`
  and enables `crew-net`, `crew-vmctl.socket` and `crew-net-site4.timer`
  at every boot, so a reprovisioned OS disk gets them back from the data
  disk; it starts them itself, since units installed mid-boot aren't in
  the boot's transaction. A rollback moves `root/current` with
  `agent/current`. An update's root half gets to `root/` through
  `crew-root-install` (see "Update notes").
- **What's still the agent's to change:** crew-vmctl's `Paths.bin`
  names `agent/current/bin` for jailer, Firecracker and the VM unit's
  `ExecStopPost=crew-vmctl exited`, so root (systemd-run, jailer before
  it drops to the VM's uid) still runs those from `agent/`. The copies
  are in `root/current/bin` for when it points there.
- **crew-net's shipped units have an ordering cycle:** `crew-net.service`
  (default dependencies, so after `basic.target`) is `Before=` the socket,
  which (also with defaults) is before `sockets.target` and so before
  `basic.target`. systemd breaks it at boot by dropping one of the jobs;
  `crew-root-units` starting both again after `basic.target` brings them
  up either way. The units want `DefaultDependencies=no` on one side, or
  no `Before=crew-vmctl.socket`.
- **`agent/` is 0711:** `CrewAgent.Identity.save/2` makes it 0700, which
  would cut crewcache off from its release in `current/cache`, so
  `crew-quota` sets it back at every boot and `provision.sh` right after
  enrollment.
- **The data disk** is formatted (`mkfs.xfs -K -L crew-data -m reflink=1`)
  only when it has no filesystem and no partition table and no disk
  already has the label, and mounted by the label with `prjquota` and
  `nofail`, so a bad one doesn't stop the boot. The mount only wants
  `crew-format-data` (ordered after it, for a first boot), and the
  formatter has no dependency on the configured device: it's skipped
  once the label exists, and otherwise scans for the label and waits up
  to 90 s for the device itself. So a disk added as `/dev/sdb` that's
  `/dev/sdc` after a reboot still mounts, whatever is at `/dev/sdb` now.
  Add box takes `/dev/...` paths including `/dev/disk/by-id/...`; the
  launchers' VMs use `/dev/vdb` (QEMU's also has the serial `crew-data`).
- **Quotas (§12.4):** project 10 is `vms/` + `jail/` (half the disk),
  11 `cache/` (a quarter), 12 `agent/` + `images/` (the rest), set at
  every boot from the disk's size. crew_cache's own default (a quarter
  of `df`) would be a quarter of its quota, so `crew-quota` writes
  `CREW_CACHE_MAX_GIB` (90% of the quota) to `/run/crew-box/cache.env`.
  XFS charges a reflinked extent to every file that shares it, so a
  clone counts its whole rootfs against the clone area: worth measuring
  on the first real box.
- **Users** have fixed ids (`_crewagent` 9100, `crewcache` 9101,
  `crewvm` 9110), so a reprovisioned OS disk owns the data disk's files.
- **First boot:** `crew-provision` joins the tailnet (with a key),
  waits for `/healthz`, starts `crew-agent-install` and
  `crew-root-units`, then `crew-net` and `crew-agent` (which wants
  `crew-cache`, and enrolls without it), and waits up to 3 minutes for
  `agent/identity.json`. Then it drops `CREW_JOIN_TOKEN` from
  `agent/env` and deletes `provision.env` and `/oem/config.ign`. Later
  boots (and a reprovisioned one) start the installed agent directly,
  and `crew-box-status` prints `crew-box: agent started`, which
  `crew-box reimage` waits for.
- **The join token** stays good through any number of Ignition fetches
  until the agent enrolls with it. A Tailscale key minted with the OAuth
  client (`Crew.Tailscale`, `tag:crew-box`, expiring with the token) is
  kept on the token for the next fetch and cleared at enrollment.
- **Tailscale's state** is bind-mounted from `/srv/crew/tailscale` into
  `tailscaled`, so the node survives a new OS disk. An update is flagged
  as `tailscale-<version>` without the bakery's `v`.
- **Development:** with `CREW_DEV=1` and an `http://` base URL the
  Ignition gives the agent `ws://` and `CREW_DEV=1`. `CREW_LISTEN_IP`
  works in dev too, so a VM on a Mac's vmnet bridge reaches the control
  plane at 192.168.64.1.
- **`crew-box reimage`** wraps the given Ignition in one that merges it
  (`ignition.config.merge`, a `data:` URL) and adds the launcher's own
  SSH key for `crew-box ssh`.

## Release and update notes

- **The control plane's image** is `docker/control-plane.Dockerfile`,
  Foreman's with Crew's names, built once per database (`CREW_DB`; the
  release is compiled for one). Both base images are pinned by digest.
  The app runs as `crew` (uid and gid 9000, fixed so the data volume
  stays the app's whatever a newer base image does with system users);
  the release under `/app` is root's, so the app can't change what it
  runs, and its scratch files go to `/tmp` (`RELEASE_TMP`). The
  compose file adds a read-only root, a tmpfs `/tmp`, no capabilities
  and `no-new-privileges`, and no Docker socket.
- **What the image carries:** the signed tarballs in
  `/app/release/agents` and the signed guest manifests in
  `/app/release/images`, from `docker/release/` at build time
  (`CREW_AGENT_RELEASE_DIR`, `CREW_IMAGE_RELEASE_DIR`). The kernel and
  rootfs aren't in it; the mirror downloads them from the release. The
  release key's public half is baked in as `CREW_RELEASE_PUBLIC_KEY`'s
  default, so a fresh deployment trusts the key its image's files were
  signed with; the env file can still override it.
- **Both listeners follow `CREW_LISTEN_IP`.** The webhook listener was
  fixed on 127.0.0.1 (§6.2), which in a container is the container's
  own loopback and can't be published. compose sets `CREW_LISTEN_IP` to
  `0.0.0.0` and publishes 4000 and 4001 on the host's loopback only, so
  §6.2's `127.0.0.1:4001` holds on the host.
- **Client addresses in the container:** Docker's proxy hands the app
  connections from the bridge's gateway, not loopback, so
  `CrewWeb.ClientIP` doesn't trust `X-Forwarded-For` there and rate
  limits key on the gateway: every client shares one budget each for
  unsigned webhooks (60 a minute), sign-ins (20 a minute) and failed
  enrollments. That's stricter, not looser, but someone on the tailnet
  sending bad join tokens could hold up a real enrollment for the
  window. Foreman's image has the same property. Trusting the gateway
  would need a configured proxy list; not done.
- **`crew-update`** (`docker/crew-update`) is Foreman's `foreman-update`
  with Crew's names (`/var/lib/crew-update`, `/etc/crew/update.conf`,
  `CREW_IMAGE` in compose's `.env`, the `crew` service), and:
  - **The request is renamed out of the container's directory before
    it's read,** then read only if it's a regular file. Foreman checks
    for a symlink and then reads, which leaves a moment for the
    container to swap in a symlink (read as root) or a FIFO (which
    would hang the run).
  - **Versions compare field by field in sh**, not with `sort -V`, and
    `is_version` refuses leading zeros and anything that isn't a digit
    or a dot before the pattern runs, so a multi-line value can't pass
    on one good line. `Crew.Updates` only offers versions this accepts.
  - **The backup leaves out `images/`:** mirrored guest images are
    large and the control plane downloads them again, checked against
    their signed manifests. The restore keeps the directory. With
    Postgres there's no volume backup, as in Foreman (the logs would
    no longer match a database that isn't restored).
  - **Every failure after the stop recovers,** not only a failed `up`
    or health check as in Foreman, where `set -e` would leave the
    control plane stopped if, say, the backup filled the disk and the
    new `.env` couldn't be written. `run.state` (in `/var/lib/crew-update`,
    root's) records the step about to start (stopping, backing up,
    pinning the image, starting the new one), and an EXIT trap (with
    INT, TERM and HUP turned into an exit) undoes what that step may
    have done: it removes a partial backup, puts the `.env` back,
    restores the backup only if the new version may have started, and
    starts the previous version. The old `.env` is renamed aside, not
    copied, so putting it back needs no space. A run killed outright
    leaves `run.state`; the next run finishes the recovery first, and
    the path unit also watches `run.state`, so that happens at boot.
    The service gets `TimeoutStopSec=10min`, so a timeout's SIGTERM
    leaves time for a health check of the previous version. An existing
    install picks up the new units by running `install` again.
  - **It can be sourced** (`CREW_UPDATE_SOURCED=1`) by
    `docker/test/crew-update-test.sh`, which runs its decisions against
    a fake docker (`docker/test/crew-update-fakes.sh`) in CI: request
    parsing (symlinks, FIFOs, extra lines, 32 bytes), version
    comparison, refused requests, a healthy update, a rollback with the
    backup restored, a crash loop, Postgres, a registry with a port, and
    a fault at each step after the stop (the backup failing, the new
    `.env` unwritable or not renamed into place, SIGTERM during the
    backup and while the new version starts, SIGKILL then the next
    run). Each run is its own `sh`, so a fault can signal it. The
    backup's tar, the units and a real pull and recreate need a Docker
    host; Foreman's DinD run (`e2e/updater/run.sh` there) isn't copied
    yet.
- **The update check** (`Crew.Updates`) is Foreman's, checked daily
  (`Crew.Updates.Check` at 05:11 UTC) rather than every five minutes,
  and at boot when there's never been a check. The result is kept in
  the settings table (`update_latest`) instead of a persistent term, so
  a restart doesn't blank the page for a day. It's one unauthenticated
  call to `CREW_UPDATE_REPO`'s releases through `Crew.GitHub.Client`
  (so `CREW_GITHUB_API_URL` and the e2e fake apply); the repo has to be
  public, as boxes download its release files without credentials too.
  It offers only tags `crew-update` would take: `vX.Y.Z`, at most four
  digits a field, no leading zeros, not a draft or prerelease.
- **"Update to X"** is on the Deployment page, which is admin-only;
  `Crew.Updates.request/2` checks the scope again, takes only the
  version the last check found newer, and refuses while a request is
  pending or a run is under way. It's audited as `crew.update` with
  `from` and `to`. The page polls the updater's `status/` every 2 s
  while it works.
- **The release key is held to a committed file,**
  `packaging/release/release-key.pub`, not a key compiled into
  `crew_protocol` (§20.1's check): no piece compiles a key in; the
  control plane, the agent and the Ignition all take
  `CREW_RELEASE_PUBLIC_KEY` at runtime. The check job requires the
  `CREW_RELEASE_PUBLIC_KEY` repository variable (what the images are
  built with) to be that file's key, and the sign job's `sign.sh
  --public-key-file` refuses a secret whose public half isn't it. So
  the secret, the variable and the images agree, and changing the key
  is a reviewed commit.
- **Versions come from the tag.** Every `mix.exs` reads `CREW_VERSION`
  (the image tools' now too), and the check job reads each one with it
  set and requires the tag's version, which is how "the tag equals
  every `mix.exs` version" holds without a version bump commit. A
  build has to pass `CREW_VERSION` through: the smoke test fails a
  tarball whose `bin/crew_agent version` isn't the tag's.
  `build-linux.sh` passes `CREW_VERSION` into its build container, not
  `CREW_VERSION`, so today its releases report 0.1.0 (found by running
  the smoke test on a real linux-arm64 build).
- **One sign job for everything.** `guest-image.yml` signed and
  verified its own manifests on tag pushes; it no longer runs on tags,
  release.yml calls it, and the release's sign job signs its manifests
  with the tarballs, so one job uses `release-signing`. `verify` then
  checks both with the committed key.
- **No separate cache job:** `build-linux.sh` makes a target's agent and
  cache tarballs together, so the agents job's Linux legs are §20.1's
  items 3 and 4. The native job is a gate (build, version, signature,
  `govulncheck`); the tarball builds compile their own helpers.
- **The supply-chain verdicts are enforced:** `docs/releases/<tag>.md`
  is the release notes and holds the review (§20.4); the check job
  fails on a missing review, an unknown verdict, or a suspicious one.
- **`govulncheck` fails today:** Go 1.24.5's standard library has
  reachable vulnerabilities fixed in later patches (GO-2025-3956,
  GO-2025-4010 and eight more, through `crew-vz`), so a release stops
  at the native job until Go is bumped (`mise.toml`, `native/go.mod`).
  CI doesn't run `govulncheck` yet for the same reason.
- **The images start once before they're pushed** (SQLite): `/healthz`,
  and no "wasn't registered" in the log for the tarballs and manifests
  baked in.
- **Ordering:** the GitHub release is published after the images and
  `:latest`, so a control plane that sees a release (its update check
  reads the releases) can pull it. A host that follows `:latest` with
  `docker compose pull` can get the image a few minutes before the
  release exists; its mirror fails to download the guest files until
  then and is retried at the next boot.
- **Not built yet:** `e2e/release-check.sh` (the aarch64 conformance on
  the M3, attached to the release); the x86_64 guest image and its
  conformance run on a hosted runner (guest-image.yml is arm64 only);
  Foreman's DinD run of the updater (`e2e/updater/run.sh` there).

## Update notes

Agent and cache updates (§20.2): `Crew.Agents.Updates` on the control
plane, `CrewAgent.Updater` on the agent, `crew-root-install` and
`crew-agent-rollback` on a Flatcar box, `crew-launch` and crew-vzd's
`restart` on a Mac.

- **`agent.update`** carries the agent tarball's `url`, `sha256`, `size`
  and `signature`, and on Linux a `cache` object with crew_cache's at the
  same version. Each signature is checked against
  `CREW_RELEASE_PUBLIC_KEY` before anything is downloaded, over this
  build's own target, so a tarball for another target doesn't verify;
  an agent without the key refuses updates (`no_release_key`). Downloads
  reuse `image.prepare`'s (capped at `size`, retried, resumed).
- **Updates download from the control plane's copies**
  (`/agent/releases/<version>/<target>/<file>`, the image's
  `CREW_AGENT_RELEASE_DIR`), as Foreman's do; only a first install
  downloads from the GitHub release. The agent swaps in the host it
  already reaches the control plane at (`CREW_URL`); the signature
  doesn't cover the URL.
- **A box's target** is its join's `os` and `arch` (`boxes.arch`, new),
  not its guests'. **Its version** is the pin, or else the newest
  registered for the target that it can update to (Linux needs the
  agent's and the cache's tarball), passing over prereleases unless
  there's nothing else.
- **When it's sent:** on join, after a release registers (to the boxes
  online), after a pin or a Retry, and from `Crew.Agents.UpdateSweep`
  every minute; to a box online, behind, with no update under way, and
  not for a version that failed twice there.
- **How it settles.** The agent answers once it has swapped releases
  (`restart: true`, with `from`), which leaves the operation `running`
  with `restart_reported_at`. It's `succeeded` when the box joins on the
  version, whatever was reported. It's `failed` when the agent refuses
  it; when the release it rolled back to reports `rolled_back` (the
  control plane takes a result for a `running` update); when the box
  joins on `from` 30 s or more after the restart was reported (sooner is
  the old release reconnecting before it exits); or when it's overdue,
  20 minutes after it was sent (the agent may wait 10 for operations) or
  10 after the restart (5 to join, and the rollbacks). A failure sends
  it again at once.
- **Two failures** of a version in a row on a box set the box's
  `failed_agent_version`, and it isn't sent there again. Updates that
  never reached the box (`offline`) don't count, and Retry (admin,
  audited) marks the failures `retried` so the version gets two more
  tries. Pinning another version clears it too. A success between two
  failures breaks the row.
- **On the agent** a release is `agent/<version>/` (the agent tarball,
  and on Linux the cache's in `cache/`), beside `current`, `previous`
  and the marker `update-pending`: JSON with `op_id`, `version`, `from`
  and `installed_at`. A tarball may hold only plain relative files and
  directories: no `..`, nothing absolute, no links of any kind (so
  `build-darwin.sh` refuses a release with links). It must hold what the
  box runs: on Linux the agent, crew-vmctl, jailer, Firecracker, the
  ruleset, the five units and crew_cache; on a Mac the agent, crew-vz,
  crew-launch and the sandbox profile.
- **The waits** come after the release is unpacked beside the current
  one and before anything moves: other operations in flight, at most 10
  minutes; then no VM `starting` (booted, without its payload: only the
  agent's memory holds the JIT config), at most 90 s. After either bound
  it goes ahead; a VM still starting is stopped on the new release's
  adoption (`boot_failed`, `agent_restart`).
- **After the swap** the agent exits 0 once every result is
  acknowledged (30 s at most), and the service manager starts `current`.
  On joining, the release `current` points at drops `previous`, the
  marker and `crashes`, and prunes releases nothing points at.
- **Rollbacks rename the marker `rolled-back`,** whoever does them, and
  the release that comes back fails the update's operation with why when
  it joins: `rolled_back`, with the reason the agent's watchdog wrote or
  "it crash-looped".
  - **Crash loops:** on Flatcar, `crew-agent.service`'s start limit (5 in
    120 s) fails it into `crew-agent-rollback.service`, as Foreman's; on
    a Mac, `crew-launch` counts starts in `agent/crashes` while an update
    is pending and switches back at the third within 120 s.
  - **No join within 5 minutes** (timed from the later of the install and
    the start): on a Mac the agent switches back itself and exits 1. On a
    Firecracker box root's half has to move too, so it exits 75, which
    `crew-agent.service` doesn't restart (`RestartPreventExitStatus=75`):
    the unit fails, and the rollback unit runs.
- **Root's half on Linux** never comes from the agent's directory. The
  agent stages `agent.tar.gz`, `cache.tar.gz` and a `request` in
  `agent/update/` (`NONCE`, `VERSION`, `TARGET`, and each tarball's
  `*_SHA256` and `*_SIG`); `crew-root-install.path` (`PathExists`, so a
  request made before a reboot still counts) starts
  `crew-root-install.service`. `root-install.sh` takes the request out of
  the agent's directory first (it's the trigger, so it can't loop),
  refuses links, copies the tarballs into `root/.update.<pid>`, checks
  both against the request and root's own copy of the release key
  (`/etc/crew-box/release-key.pem`, which the Ignition now writes in the
  reprovision mode too), installs the root half with the first install's
  code (`lib.sh`'s `root_half`), moves `root/current`, puts the units in
  place, and answers `ok <nonce> <version>` or `error <nonce> <why>` in
  `root/update.result`. The agent waits for its nonce (3 minutes at
  most), then moves its own `current` and restarts crew-cache through
  `crew-vmctl restart-cache`.
- **A changed ruleset is loaded with `crew-vmctl net-up` directly,** not
  by restarting crew-net: `crew-agent.service` and `crew-cache.service`
  `Requires=` crew-net, so a restart would restart the agent in the
  middle of its update. net-up puts the running VMs' `vm_pairs` back. If
  it fails, root goes back to the old release's half and answers an
  error. The rollback unit still restarts crew-net.
- **What root takes from the agent's directory** is only ever a name or
  bytes it checks, never a path:
  - Versions and the request's fields go through `lib.sh`'s `one_line`
    first, which refuses any character a value doesn't need (a newline
    among them). grep matches line by line, so `release_version` used
    to pass a multi-line value on one good line, and a compromised agent
    could point `previous` at `../agent/payload` plus a version line,
    exit 75, and have the rollback unit point `root/current` at its own
    directory and start its units (found in review, reproduced, and now
    a regression test). Links are read with `readlink -n` exactly
    (`exact_link`): `$(readlink)` drops trailing newlines.
  - The rollback moves root's half only to a release root installed:
    `root/<version>` that's a directory, not a link, owned by root
    (`root_release`); otherwise only the agent goes back.
  - `root-install.sh` renames the request and the tarballs into its own
    directory before it looks at them, so they can't be swapped for a
    link or a FIFO between the check and the read.
  - What's written into `agent/` is written in root's directory and
    renamed in (the first install's `env`), and a link target printed to
    the consoles is printed only if it's a version.
- **Root keeps** the new release's half, the one before it and the one
  the agent's `previous` names; the rest go. The first install's
  `agent/<version>/` stays root's and read-only, so the agent can't
  prune it; an update back to that version reuses it as it was checked.
- **What's left inconsistent:** if the agent dies after root answered
  and before it moves its own `current` (nothing is pending then, so
  nothing rolls back), `root/current` stays a version ahead until the
  next update.
- **On a Mac the releases are the agent's,** in
  `<data>/agent/<version>/` (`agent/` is 0750 `_crewagent:crewvm`, the
  release files not group- or world-writable), not root's
  `/usr/local/crew`: the agent updates itself and there's no root daemon
  to install anything (§10.8). Both LaunchDaemons run from
  `agent/current`: the agent through `crew-launch`, crew-vzd as
  `agent/current/bin/crew-vz` with `agent/current/share/sandbox.sb`. That
  lets `_crewagent` change what `_crewvm` runs; neither is root, and the
  agent already starts every VM through crew-vzd.
- **crew-vzd's update:** it resolves its own path and the sandbox
  profile's at start, so it keeps launching helpers from the release it
  started from. The agent (`CrewAgent.Driver.VZ.Upgrade`, every 30 s)
  asks crew-vzd's `version`, and once it differs from `current`'s and no
  VM runs, asks it to `restart`; crew-vzd refuses (`busy`) while any VM
  runs or is starting, else exits for launchd to start the new one. It's
  asked once per version, and crew-vzd's release is kept when old ones
  are pruned.
- **`install-macos.sh`** installs the release it's run from as the
  update leaves one, and writes `CREW_RELEASE_PUBLIC_KEY` from
  `--release-key` (Add box's command carries it, beside the fingerprint
  the admin compares), kept on a reinstall. The darwin tarball
  (`packaging/release/build-darwin.sh`) is the agent's release with
  `bin/crew-vz`, `bin/crew-launch`, `share/sandbox.sb`, `launchd/`,
  `install-macos.sh` and `VERSION` at its root. It doesn't carry vfkit
  (§20.1 lists it): that's the mac-vm launcher's, not a mac-vz box's.
- **An update depends on the tarballs' versions:** a box is sent its
  target until it joins on that version, so a release whose
  `bin/crew_agent version` isn't its tag's would be sent forever. Both
  builds pass `CREW_VERSION` (the smoke test holds them to it).
- **Tests:** the agent's `UpdaterTest`, `RootStepTest`,
  `VZ.UpgradeTest` and `CrewLaunchTest` (crew-launch run for real);
  crew-vzd's `version` and `restart` in `native/`; the control plane's
  `UpdatesTest` and the box page; `FlatcarRootInstallTest` runs
  `root-install.sh` and `agent-rollback.sh` against signed fixtures with
  `systemctl` stubbed; `e2e/tests/13-agent-update.spec.js` (`E2E_AGENT_UPDATE=1`)
  updates a real development release to another and rolls back one that
  crashes, twice.
