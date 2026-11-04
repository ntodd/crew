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
