# Security model

What Crew protects, where the trust boundaries are, what defends each
one, and what it knowingly doesn't. Written to be red-teamed: "Known
gaps" and "Things worth trying" are the places to start. The spec's
§19 is the source; this file says how the code meets it, and where it
departs.

## What's worth stealing

| Asset | Where it lives |
|---|---|
| GitHub App private key, webhook secret, client secret | Control plane DB, encrypted (Cloak, AES-256-GCM), or its environment |
| GitHub user tokens | Control plane DB, encrypted |
| JIT runner configs | `Crew.VMs.Server` memory (redacted from crash reports) → `vm.start` over WSS → the agent's memory → the guest API, once (a second fetch is 410) → `/run/crew/jit` in the guest, deleted once the runner has read it. Never written to a table: operations store commands with secrets removed. |
| Agent private keys | `${CREW_DATA_DIR}/agent/identity.json` (0600, `_crewagent`) |
| The release signing key | A protected GitHub Environment (`release-signing`), usable only from `v*` tags, by the sign job alone |
| Cache CA keys | Each box cache's `cache/ca/` (0600, `crewcache`). The root key is destroyed as soon as the intermediate is signed. |
| Registry credentials in transit | Jobs' `docker login` tokens never reach the cache: with mirrors (Design A) dockerd keeps credentials for the real registry and sends the mirror anonymous requests |
| Join tokens and Tailscale auth keys | Hashed in the DB (join tokens) or encrypted (Tailscale keys); in a box's Ignition until it enrolls, then deleted from `/etc/crew-box` and the OEM partition |
| Logs | The control plane's data volume (`CREW_LOG_DIR`) |

## Trust boundaries

### Job VM and host (the main boundary)

**Firecracker boxes (`linux-metal`, `linux-vm`, `mac-vm`):**

- KVM and Firecracker's small device model, started through the jailer:
  a chroot per VM, a unique uid and gid (`200000 + lease`), a private
  `/dev/kvm` and `tun` node, seccomp. systemd owns every limit
  (`MemoryMax`, `TasksMax`, `RuntimeMaxSec`), and the VMM is the unit's
  main process. `--no-api`: the whole configuration is a file, so there's
  no API socket to protect.
- **The agent isn't root.** It runs as `_crewagent` with
  `NoNewPrivileges` and `ProtectSystem=strict`, and serves the guest API
  to hostile guests. Root work goes through `crew-vmctl`, socket-activated
  per connection (`/run/crew/vmctl.sock`, 0660 `root:_crewagent`), with a
  fixed list of verbs. No verb takes a free-form path, command or
  argument: ids are UUIDs, leases bounded integers, and `start` re-reads
  the VM's files itself.
- **crew-vmctl doesn't trust the agent's files.** Everything under
  `/srv/crew` is opened with `openat2(RESOLVE_BENEATH | NO_SYMLINKS)`. The
  clone must have one link and belong to the connecting uid, and is
  hard-linked into the jail through the descriptor that was checked.
  `fc.json` is decoded strictly (unknown fields refused) and rebuilt for
  the chroot. The console and stderr files live in the root-owned jail,
  because systemd opens them as root and follows symlinks. VM uids that
  collide with `/etc/passwd`, `/etc/group` or a subordinate-id range are
  refused.
- **Root runs nothing the agent can write.** The agent updates itself in
  `/srv/crew/agent`, so everything root runs (crew-vmctl, jailer,
  Firecracker, the ruleset, the units) comes from a root-owned copy in
  `/srv/crew/root/<version>`, which a root step installs from a tarball
  whose signature it checks.
- **Cleanup is durable.** A VM's lease stays held until its cleanup
  succeeds; a failed cleanup is retried, and jails with no agent record
  are reconciled. `pair-del` and `tap-del` refuse a lease another VM's
  jail still holds.

**vz boxes (`mac-vz`):**

- Apple's hypervisor, with `crew-vz` running as `_crewvm` under a
  `sandbox-exec` profile. The guest's network is a userspace stack
  (gVisor's netstack, vendored) inside `crew-vz`, which only forwards to
  the destinations §14.4 allows.

### Host VM and physical host

`linux-vm` and `mac-vm` boxes add a second hypervisor boundary: Flatcar
in QEMU (Linux) or vfkit (macOS), with nested virtualization for
Firecracker inside it.

### Job VM and the network

**On Firecracker boxes,** the `inet crew` nftables table (§14.2), loaded
once at boot by `crew-net` and verified every 60 s:

- One tap per VM, `crewt<n>`, unbridged, `disable_ipv6`, `rp_filter`.
  Anti-spoofing (`iifname . saddr` must be in `vm_pairs`) runs before
  conntrack, so a spoofed packet can't ride another VM's flow; an empty
  `vm_pairs` drops everything from VMs.
- To the host: only `10.199.0.1` on 53, 80, 443 and 7777, and pings to
  `10.199.0.1` (rate-limited). Nothing else.
- Forwarded: only new and established traffic out of the uplink, never
  to `blocked4` (private, link-local, CGNAT and reserved ranges) or
  `site4` (the uplink's subnets, the site's public egress addresses and
  the admin's extra blocked ranges). IPv6 from VMs is dropped.
- At most 2048 tracked connections per VM (iptables-nft `xt_connlimit`,
  since Flatcar's kernel has no `nft_connlimit`).
- **site4 comes from root's side only.** Egress addresses, as the agent
  learns them, are add-only: root keeps every one it has seen (up to 64),
  so an agent can add an address but never remove one. The extra blocked
  ranges and the uplink come from root-owned files the Ignition writes.
- **A broken filter stops VMs.** `nft-verify` loads the shipped ruleset
  into a fresh network namespace and compares the box's table with it,
  site4 included. Two failed checks in a row force-stop every VM, and
  starts are refused until a check passes. crew-vmctl's `start` runs its
  own check too.

**On vz boxes,** `crew-vz`'s netstack enforces the same matrix in Crew's
own code (see Known gaps).

### Job VM and the cache

- The cache is read-only to guests: they can pull, never push (writes
  get 405).
- Content-addressed and verified: a manifest is checked against its
  digest before it's served, and a blob streams to the client and a temp
  file at once, with its last byte held back until the SHA-256 matches.
- Nothing fetched with credentials is stored. With mirrors, the cache
  fetches as its own anonymous client against each host's compiled token
  realm (a registry's own challenge never picks the realm), and anything
  not served (repos off the allowlist, private repos, disabled hosts,
  tag lists) is a 404, so dockerd goes to the registry itself with its
  credentials. The cache never becomes a proxy for them.
- Upstreams are compiled into the release. Tags are always resolved
  against the real upstream, never the parent cache.
- The cache resolves every upstream and redirect target itself, and
  refuses `blocked4` and `site4`.
- The CA chain: a name-constrained intermediate (permitted: the cache's
  IP only; excluded: every DNS name) under a root whose key is gone, so
  nothing else can ever be signed under the root guests trust.
- A guest can't exhaust the cache's disk: every download reserves its
  space before writing, including chunked ones.

### Agents and the control plane

- Agents dial out (WSS; plain `ws://` only with `CREW_DEV`); boxes need
  no inbound ports.
- Enrollment spends a single-use join token, claimed with one
  conditional update, so racing enrollments can't both win. The agent
  makes its own ed25519 keypair; only the public key leaves the box.
- Every socket connect is signed (agent id, time, nonce); bad
  signatures, clocks off by more than the allowed skew, and nonces seen
  before are refused, and failures are rate-limited per client.
- A fixed command and event vocabulary, validated by `CrewProtocol` on
  both sides. An agent reports only on its own box's VMs and operations.
- Capabilities are pinned at enrollment; a later report that grows
  past them needs an admin's approval, so a stolen key can't claim a huge
  box and draw in the fleet's jobs.
- No distributed Erlang anywhere (`RELEASE_DISTRIBUTION=none`).

### Webhooks

Their own listener with one route (`POST /hooks/github`), bodies over
5 MiB refused before they're read, `X-Hub-Signature-256` verified, bad
signatures rate-limited per client (correct ones never are), deliveries
deduplicated by id, and processing queued so GitHub's timeout never
waits on it. Funnel exposes that port only.

### People and the control plane

Foreman's model: GitHub sign-in through the App's OAuth flow, sessions
in a signed and encrypted cookie (`SameSite=Lax`, 30 days), a CSP with
no inline scripts or style attributes (`style-src 'self'`; Oban Web's
pages are the one exception), `frame-ancestors 'none'`. Admin pages 404
for members. Members see jobs in repos they can't read as "a job in
another repo", on every fleet-wide page (dashboard, queue, boxes),
including a repo's custom labels and its stall reasons.

### Code

Agents, caches, guest images and the helpers are signed with the release
key and checked before use: a guest image's manifest (and then each
file's SHA-256) by the control plane when it registers it and by the
agent when it prepares it; an agent or cache tarball by the Flatcar
install and by the updater. A compromised control plane can't push
code.

## What a compromised piece can do

| Compromised | Can | Can't |
|---|---|---|
| A job | Use its VM's resources until the deadline; reach the public internet; lie in its own live log, steps and metrics; read its own (spent) JIT config | Reach other VMs, the host, the LAN, the tailnet or the site's public IP; persist; write to the cache; change GitHub's authoritative log |
| A host VM (after a VM escape and a root escalation) | Everything on that box: its VMs, their JIT configs, the cache CA, the agent key (so act as that box and receive the jobs placed on it) | Change its pinned capabilities without an admin's approval; reach other boxes' VMs; sign code; read logs of jobs on other boxes |
| An agent (as `_crewagent`) | Everything an agent key can; read the JIT configs of its own box's VMs | Run anything as root outside crew-vmctl's verbs; weaken the packet filter or remove an egress address from site4; replace what root runs |
| An agent key alone | Pose as that box and receive the JIT configs placed on it | Claim more capacity (pinned); act for other boxes |
| The control plane | Create runners on every installed repo and change repo settings there (Administration: write); approve fork-PR runs and cancel or re-run anything (Actions: write); read all logs; change the cache allowlist | Push agent, cache, guest or helper code; redirect cache upstreams; make the cache CA vouch for other names; run commands on boxes |
| The parent cache | Refuse service | Serve wrong content (digests are verified, and tags are never resolved through it) |

## Known gaps

1. **Administration: write is broad.** GitHub has no narrower permission
   for repo-level runners. Keep the App installed only on the repos that
   use Crew, and the control plane tailnet-only.
2. **Public repos.** Fork-PR refusal is enforced in the VM before any
   job code runs (below), but repos should still require approval for
   outside contributors. Workflows triggered by `issue_comment` or
   `pull_request_target` run the base repo's workflow on Crew: treat
   those triggers as running untrusted input.
3. **Egress is open** to the public internet, as on GitHub's own
   runners: abuse, mining, exfiltration of whatever the job has.
4. **Live data is untrusted.** The live log, steps and metrics come from
   inside the VM. GitHub's log, once fetched, is shown as authoritative.
5. **The guest API token is readable in the guest,** by design. It's
   per VM, and the guest API refuses another VM's token.
6. **Nested virtualization isn't a supported Firecracker setup.**
   `linux-vm` and `mac-vm` trade it for not needing a dedicated machine.
   `linux-metal` is the hardened option, and repos can be pinned to it.
7. **The vz driver's network isolation is Crew's own code:** the
   userspace stack in `crew-vz`. A bug there is an isolation bug. It runs
   sandboxed as `_crewvm`.
8. **First install trusts the Ignition.** A Flatcar box checks its
   tarballs against the release key embedded in the Ignition, which the
   control plane writes. Compare the fingerprint on Add box with the
   published one, or the first install trusts the control plane.
9. **In-memory state** (rate limits, the connect nonce cache) resets on
   restart.
10. **Development conveniences** (`CREW_DEV=1`): the null driver, `ws://`
    agents, and control-plane URLs for tarballs. Never set it in
    production; the release refuses the null driver without it.
11. **crew-vmctl doesn't check that `root/current/bin` is root-owned**
    before using it; that rests on the install step.

## Fork PRs

**Enforcement is in the VM, before any job code runs.** The runner's
job-started hook (`/opt/crew/hooks/job-started.sh`, baked into the signed
image; GitHub fails the job when it exits non-zero) reads
`$GITHUB_EVENT_NAME`, `$GITHUB_EVENT_PATH` and the repo's `fork_prs`
policy from `/run/crew/policy.json`. For `pull_request`,
`pull_request_target`, `pull_request_review` and
`pull_request_review_comment`, with the policy `refuse`, it exits 1 when
`pull_request.head.repo` is null or its `full_name` differs from
`repository.full_name`, prints "Crew: fork PRs are refused on this
repo" and reports `job_refused`.

**The control plane also checks, as an optimisation:** a job whose run
isn't known yet is blocked ("checking fork status") and isn't demand; a
fork PR under `refuse` becomes unsatisfiable, its run is cancelled and
audited; a Crew VM that picks one up anyway is force-stopped.

## Things worth trying

**From a job:** reach the host on any non-service port, another VM, the
LAN, the tailnet, `169.254.169.254`, the site's public IP or the Mac;
spoof another VM's address or inject into its flows; send IPv6 RAs;
exhaust conntrack; fill the host disk; flood the console, log, steps or
state endpoints; fetch a second payload or use another VM's token;
forge `job_finished` or `job_refused` for another VM.

**Against the cache:** get a private image served to another job (tags,
`Accept` variants, `Authorization` reuse, redirects to private
addresses); get a certificate for a non-registry name; poison the store
through the parent; fill its disk with chunked downloads.

**Against the root helper, as `_crewagent`:** make crew-vmctl touch a
path outside `/srv/crew` (symlinks, hard links, renamed directories);
start a VM whose uid matches a real user; delete another VM's tap; drop
an egress address from site4; get root to run a binary the agent wrote.

**Fork PRs:** get one past the hook: other event types, a null head
repo, a renamed fork.

**Against the control plane:** as an agent, act on another box's VMs,
replay a connect, or report inflated capabilities; through logs, script
injection in the UI (ANSI, HTML, `javascript:`, giant lines) and ReDoS
through search; as a member, read a repo's logs without GitHub access
through any page, event, search or download, or see private repo names
or labels on the dashboard, queue or boxes; through webhooks, forge,
replay, send 25 MB payloads, or flood the endpoint to crowd out GitHub's
deliveries.
