# Architecture

[crew_spec.md](crew_spec.md) is the design. This file records what
building it settled: the spike results, and decisions the spec left to
the build.

## Spike results

| # | Result |
|---|---|
| S2 | Resolved before the build, by ntodd/foreman#132 (spec §24). |
| S8 | **Mirrors (Design A).** dockerd 29.9.2 with the containerd image store (`driver-type=io.containerd.snapshotter.v1`, the default for a fresh daemon) reads `/etc/docker/certs.d/<registry>/hosts.toml` for any registry, not `/etc/containerd/certs.d` (moby#47380, since 28.0). `e2e/s8/run.sh` pulls `ghcr.io/actions/actions-runner`, `docker.io/library/alpine` and `public.ecr.aws/docker/library/busybox` through crew_cache at 10.199.0.1 from a dind daemon with crew-guest's files: the first pulls are misses, the second all hits, and a repo off the allowlist (a 404 from the cache) falls back to the registry. Mirrors get `capabilities = ["pull", "resolve"]` explicitly, since without them containerd sends pushes to the first host too. |

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
  in `POST /config` (the egress address it learns). The agent doesn't
  push it yet.
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
- **Space and load:** a download with a `Content-Length` reserves it in
  the store before it writes, so downloads in flight count against the
  quota, and one that can't fit is a 404 (containerd goes upstream). One
  object may take at most half the quota. At most 512 fetches run at
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
- **Counters** (`GET /stats`) run from the cache's start. A hit is an
  object served from the store, a miss one fetched; a tag request counts
  as its manifest. `bytes_stored` is what the store holds now, per host;
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
