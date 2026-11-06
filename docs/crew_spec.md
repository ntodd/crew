# Crew: self-hosted, VM-isolated GitHub Actions runners

Status: revision 3, ready for implementation, 2026-11-01. Revision 1 went
through two independent adversarial reviews: correctness and completeness,
then security and platform realism. Every finding from both is resolved
in revision 2. Revision 3 takes the host-VM launchers from Foreman's
Flatcar boxes (ntodd/foreman#132), which settled spike S2.
[Appendix A](#appendix-a-review-log) lists what changed.

Audience: the engineer or agent building Crew end to end. Everything here is
meant to be buildable as written. Where a fact still has to be confirmed on
real hardware, it's listed under [Spikes](#24-spikes) with a fallback, and the
build order runs those spikes first.

"Crew" is a working name: a crew works under a foreman, and Crew copies
[Foreman](https://github.com/ntodd/foreman) wherever it can. Renaming is a
find-and-replace on `crew` / `Crew` / `CREW_`.

**Conventions:**
- **Must** and **must not** are requirements. **Should** is the default
  unless there's a stated reason not to.
- "Copy Foreman's X" means take that module, doc or pattern from
  `ntodd/foreman` and adapt it. It doesn't mean depend on Foreman's code.
  Where Crew must *differ* from Foreman, the difference is called out.
- Durations are in seconds unless a unit is given. "MiB" and "GiB" are
  binary units.

---

## Contents

1. [Summary](#1-summary)
2. [Goals and non-goals](#2-goals-and-non-goals)
3. [Glossary](#3-glossary)
4. [Architecture and code layout](#4-architecture-and-code-layout)
5. [Hosts and deployment](#5-hosts-and-deployment)
6. [GitHub integration](#6-github-integration)
7. [Labels and sizes](#7-labels-and-sizes)
8. [Scheduling](#8-scheduling)
9. [Control plane](#9-control-plane)
10. [Agent and protocol](#10-agent-and-protocol)
11. [Drivers](#11-drivers)
12. [Host VMs and Flatcar](#12-host-vms-and-flatcar)
13. [Guest image and guest contract](#13-guest-image-and-guest-contract)
14. [Networking and isolation](#14-networking-and-isolation)
15. [Registry cache](#15-registry-cache)
16. [Live logs and job telemetry](#16-live-logs-and-job-telemetry)
17. [UI](#17-ui)
18. [Sign-in and authorization](#18-sign-in-and-authorization)
19. [Security model](#19-security-model)
20. [Releases, signing and updates](#20-releases-signing-and-updates)
21. [Configuration reference](#21-configuration-reference)
22. [Data model](#22-data-model)
23. [Testing](#23-testing)
24. [Spikes](#24-spikes)
25. [Build order](#25-build-order)
26. [Decisions](#26-decisions)
27. [Later](#27-later)
- [Appendix A: review log](#appendix-a-review-log)

---

## 1. Summary

Crew runs GitHub Actions jobs on hardware you own, each job in its own
throwaway virtual machine. Nothing is assigned to a repo ahead of time:

1. GitHub queues a job that asks for a Crew label.
2. The control plane picks a box with room, and asks GitHub for a
   single-use (JIT) runner registration.
3. It tells that box's agent to boot a VM with the registration.
4. The runner takes a job, runs it and exits. The VM is destroyed.

Thirty queued jobs on boxes that hold 7, 3 and 6 run 16 at once, and the
other 14 start as slots free up.

**The pieces:**
- **Control plane:** a Phoenix app, copied from Foreman's:
  - GitHub sign-in, LiveView UI, SQLite or Postgres;
  - agents connect over WSS, with each connect ed25519-signed.
  - New for Crew: it takes GitHub webhooks, keeps the job queue, places
    jobs, and shows runs, live logs and metrics.
- **Agent:** an Elixir release on each box, copied from Foreman's agent. It
  dials out, boots and destroys VMs through a pluggable **driver**, and
  updates itself from signed releases.
- **Drivers:**
  - `firecracker`: Linux KVM, on Linux boxes and on the M3 Max inside a
    Flatcar host VM.
  - `vz`: Apple's Virtualization.framework, used directly on the M1 Ultra.
- **Isolation:** every job gets its own VM and kernel, with a firewall that
  allows only the internet and a few Crew service ports. On Firecracker
  boxes, the agent, cache and VMs also live inside a Flatcar host VM or on a
  dedicated bare-metal Flatcar install.
- **Registry cache:** each box runs a pull-through cache, shared by its job
  VMs, for Docker Hub, GHCR, ECR Public and the other common public
  registries.

## 2. Goals and non-goals

### Goals

1. **Elastic, shared capacity.** Any job from any connected repo can run on
   any box that fits it. No runners are pre-provisioned.
2. **One VM per job.** A job never shares a kernel, filesystem, network
   stack or Docker daemon with another job. Nothing it writes outlives it,
   except what the registry cache fetched from upstream on its behalf
   (§15).
3. **Sizes.** Workflows pick a named size (`crew-m`, `crew-l`…) that sets
   vCPUs, memory and disk, enforced by the VM.
4. **Fast starts.** On a box with the image ready and room free, the time
   from Crew seeing a queued job to the runner listening has a target of
   p50 ≤ 5 s and p95 ≤ 10 s. It's measured and shown (§16.4).
5. **A shared registry cache** on each box, plus an optional parent cache
   on the LAN.
6. **A UI better than GitHub's for this fleet:** the queue and why each job
   waits, live runs, live logs, per-job resource charts, and box metrics.
7. **Foreman's operational model:** GitHub sign-in with the same
   allowlists, agents that dial out, signed releases, self-updating agents,
   an audit log.
8. **Pluggable drivers,** proven by shipping two (`firecracker` and `vz`)
   that pass one conformance suite.
9. **Mixed architectures:** x86_64 Linux and arm64 Macs in one fleet. Jobs
   are placed by the arch they ask for, or wherever there's room when they
   don't care.

### Non-goals (v1)

- **No macOS or Windows guests.** Linux guests only.
- **No GPUs.**
- **No GitHub Enterprise Server.** github.com only.
- **No org-level runners or runner groups.** v1 registers every runner on
  its repo, which works for personal accounts and orgs alike (Later).
- **No compatibility with GitHub's `ubuntu-latest` image.** Crew ships its
  own image, and workflows use `setup-*` actions for toolchains.
- **No local `actions/cache` server and no sticky disks** (Later).
- **No multi-tenancy.** One deployment serves one person or one team.
- **No jobs without a VM.** The only non-VM driver is a dev-only fake that's
  compiled out of production builds.

## 3. Glossary

| Term | Meaning |
|---|---|
| **Control plane** | The Phoenix app. It owns all durable state. |
| **Box** | A machine that runs jobs, with one agent and one driver. |
| **Agent** | The Elixir release on a box. Its only durable state is under `${CREW_DATA_DIR}/agent/` (§10.1). |
| **Driver** | The agent module that starts and stops VMs on one kind of host. |
| **Host VM** | The Flatcar VM a Firecracker box lives in (on a Mac, or on a Linux host that does other work). |
| **Service VM** | A Flatcar VM on the M1 that runs the control plane and the parent cache. Not a box. |
| **Cache VM** | A Flatcar VM on the M1 that runs the box cache for the `vz` box's job VMs. Not a box. |
| **Job VM** | The single-use VM a job runs in. |
| **Job** | A GitHub `workflow_job`: one job, or one matrix leg, of one run attempt. |
| **Label key** | A job's `runs-on` labels, lowercased, deduplicated and sorted. |
| **Class** | `(repo, label key)`. A runner registered for a class can take any queued job of that class (§8.1). |
| **Size** | A named vCPU / memory / disk allocation. |
| **Image** | A guest image: kernel plus root filesystem, per arch, signed. |
| **crew-guest** | The guest init service, started by systemd in the job VM. It fetches the payload, runs the runner and reports back. |
| **Guest API** | The HTTP API the agent serves to job VMs (§13.4). |
| **Payload** | What a job VM gets once, at boot: the JIT config, the cache CA, the policy. |
| **Deployment id** | A random 4-character id for each deployment (`[a-z0-9]{4}`), generated at setup, that prefixes every runner name. |

## 4. Architecture and code layout

```
                     GitHub (webhooks, REST API)
                        │ webhooks: Tailscale Funnel :8443 → one-route endpoint
                        ▼
 Browser ─LiveView─► Control plane (Phoenix · SQLite/Postgres · Oban) ── tailnet only
                        ▲ wss:// over the tailnet; agent dials out; signed connect
     ┌──────────────────┼──────────────────────────────┐
 Linux box           M3 Max box                    M1 Ultra box
 Flatcar (metal or   macOS → vfkit --nested →       macOS
  host VM on KVM)     Flatcar host VM (nested)       ├ crew agent (darwin, _crewagent)
 ├ crew agent        ├ crew agent                   ├ crew-vzd (LaunchDaemon, _crewvm)
 ├ crew-vmctl (root) ├ crew-vmctl (root)            │   └ crew-vz ×N → job VMs (arm64)
 ├ crew cache        ├ crew cache                   ├ cache VM (Flatcar): crew cache
 └ firecracker ×N    └ firecracker ×N               └ service VM (Flatcar): control
   (jailed, x86_64)    (jailed, arm64)                plane + parent cache
```

A monorepo of separate Mix projects, like Foreman's, and not an umbrella:
the pieces ship on different schedules.

```
apps/
  crew/            # Phoenix control plane
  crew_agent/      # agent release: linux-amd64, linux-arm64, darwin-arm64
  crew_protocol/   # shared structs + validation: commands, events, guest API, labels
  crew_cache/      # registry cache + guest DNS: linux-amd64, linux-arm64
  crew_guest/      # guest init release, baked into the guest image
native/
  crew-vmctl/      # Go: Linux root helper with fixed verbs (§10.8)
  crew-vz/         # Go: VZ helper (one per VM) and crew-vzd supervisor (darwin-arm64)
  vendor/          # every Go module vendored and committed (§20.1)
images/
  guest/           # guest image: package lock, kernel configs, build scripts
  flatcar/         # Butane templates: box, cache VM, service VM
docs/              # architecture.md, security.md, releasing.md, setup/*.md
e2e/
```

- **Elixir everywhere except `native/`.** The `native/` code exists because:
  - Apple's frameworks need native code, and a crash in a NIF would take
    down the BEAM, so that code runs as separate processes;
  - `crew-vmctl` keeps root out of the BEAM that faces guests.
- **Go modules are vendored and reviewed** like every other upstream
  (§20.1).

## 5. Hosts and deployment

### 5.1 Box types (v1)

| `boxes.type` | Stack | Driver | Guest arch |
|---|---|---|---|
| `linux-metal` | Bare-metal Flatcar → agent | `firecracker` | the host's (x86_64 or arm64) |
| `linux-vm` | Linux with KVM and `nested=1` → Flatcar host VM → agent | `firecracker` | x86_64 |
| `mac-vm` | macOS 15+ on M3 or later → `vfkit --nested` → Flatcar host VM → agent | `firecracker` | arm64 |
| `mac-vz` | macOS on Apple Silicon → agent (native) → `crew-vzd` → `crew-vz` per job | `vz` | arm64 |

- **Two hypervisors deep at most** (a host VM on the physical host). A
  Crew box inside a VM that's itself a guest isn't supported.
- **Nesting is reported, not guessed:**
  - The agent reports `virtualized: bool` and `hypervisor_vendor` (CPUID
    leaf 0x40000000 on x86, DMI `sys_vendor` on arm64).
  - The box page shows them.
  - The setup docs explain that a `linux-vm` box must run on the physical
    host.
- `mac-vm` depends on spike S1; `mac-vz` on S3 and S4.

### 5.2 The reference deployment

| Machine | Runs |
|---|---|
| M1 Ultra | The service VM (control plane, parent cache), the cache VM, and a `mac-vz` box |
| M3 Max | A `mac-vm` box |
| Linux machines | `linux-metal` boxes where they're dedicated, `linux-vm` otherwise |

The control plane is a GHCR image run with compose, like Foreman's. It can
run anywhere Foreman's can; the M1 service VM is a recommendation, not a
requirement.

### 5.3 Reachability

- **The control plane is reachable only over the tailnet.**
  - People reach it through `tailscale serve` on 443, as with Foreman.
  - Agents reach it with `CREW_URL=wss://<host>.<tailnet>.ts.net/agent/websocket`.
  - Plain `ws://` is refused unless `CREW_DEV=1`.
- **Every box joins the tailnet.**
  - **Flatcar boxes:** the Tailscale sysext, enrolled by an auth key in
    its Ignition. Copy Foreman's: the control plane mints the key with
    its Tailscale OAuth client (`CREW_TAILSCALE_CLIENT_ID`,
    `CREW_TAILSCALE_CLIENT_SECRET`), or the admin pastes one on **Add
    box** when there's no OAuth client. The key is single-use,
    pre-authorised, tagged `tag:crew-box`, expires with the join token,
    and is deleted from the box after its first `tailscale up`.
  - **macOS boxes:** the Tailscale app.
  - The tailnet ACL grants `tag:crew-box` access to the control plane's
    node on 443 and to the parent cache on 5443, and nothing else. The docs
    give the ACL snippet.
- **GitHub reaches one endpoint only:** the webhook receiver, through
  Tailscale Funnel on port 8443 (§6.2).
- **Nothing reaches an agent.** Agents always dial out.

## 6. GitHub integration

### 6.1 The App

One GitHub App per deployment, created from a manifest on `/setup`. The
flow is Foreman's (`Foreman.Setup`, the setup controller and
`docs/setup/github-app.md`), but **Crew's manifest is different**:

```json
{
  "name": "Crew (<deployment id>)",
  "url": "https://<tailnet host>",
  "hook_attributes": { "url": "https://<tailnet host>:8443/hooks/github", "active": true },
  "redirect_url": "https://<tailnet host>/setup/github/callback",
  "callback_urls": ["https://<tailnet host>/auth/github/callback"],
  "setup_url": "https://<tailnet host>/setup/github/installed",
  "public": false,
  "request_oauth_on_install": false,
  "default_events": ["workflow_job", "workflow_run"],
  "default_permissions": {
    "administration": "write",
    "actions": "write",
    "metadata": "read",
    "pull_requests": "read",
    "members": "read"
  }
}
```

| Permission | Why |
|---|---|
| Administration: write | Creating repo-level JIT runners, and listing and deleting runners. There's no narrower repository permission for these (§19.4 #1). |
| Actions: write | Reading runs, jobs and logs; cancel and re-run; cancelling refused fork runs. Actions: read is also what lets the App receive `workflow_job`. |
| Metadata: read | Required |
| Pull requests: read | PR numbers and titles in the UI |
| Members: read (org) | `CREW_ALLOWED_ORG` sign-in checks, as in Foreman |

The setup page asks for the tailnet hostname (stored in `settings.public_host`)
and builds every URL from it. Crew records what each installation actually
granted at every sync, as Foreman does. A missing permission disables the
feature that needs it, and the repo page flags it. Members is an
organization permission, which GitHub never grants an installation on a
personal account, so it's never missing there.

### 6.2 Webhook ingress

- **Endpoint:** a second Bandit endpoint, `CrewWeb.HookEndpoint`, on
  `127.0.0.1:${CREW_HOOK_PORT}` (default 4001). It has exactly one route,
  `POST /hooks/github`: no sessions, LiveView, static files or other plugs.
  Copy Foreman's `docker/compose.yml` and also publish
  `127.0.0.1:4001:4001`.
- **Exposure:** `tailscale funnel --bg --https=8443 http://127.0.0.1:4001`.
  The UI stays on `tailscale serve` 443, tailnet-only. Funnel is set per
  port, so the UI is never public. The setup docs give both commands.
- **Handling a request, in order:**
  1. Refuse bodies over 5 MiB (413) before reading them.
  2. Verify `X-Hub-Signature-256`: an HMAC-SHA256 of the raw body with the
     webhook secret, compared with `Plug.Crypto.secure_compare/2`. On
     failure, answer 401.
     - Failures are rate-limited per client, using Foreman's
       `ForemanWeb.ClientIP` (the last `X-Forwarded-For` entry, trusted
       only from loopback), at 60 a minute.
     - **Correctly signed requests are never rate-limited.**
  3. Insert `webhook_deliveries(github_delivery_id)`. If the id already
     exists, answer 200 and stop.
  4. Enqueue `Crew.GitHub.HookWorker` with the event name, the action and
     the decoded payload in its args. Oban uniqueness is on
     `(event, object id, action)`.
  5. Answer 202. GitHub's 10-second timeout never waits on processing.
- **Missed deliveries:** GitHub doesn't redeliver on its own.
  - Every 5 minutes, and at boot, `Crew.GitHub.Redeliver` lists
    `GET /app/hook/deliveries` (JWT auth) back to the newest delivery
    already processed, at most 3 days back.
  - For each failed delivery that isn't in `webhook_deliveries`, it calls
    `POST /app/hook/deliveries/{id}/attempts`.
  - The reconciler (§8.8) covers anything that still slips through.
- **Poll-only mode** (`CREW_WEBHOOKS=off`, for deployments without Funnel)
  is supported, with the costs in §8.8. The Deployment page says jobs may
  wait up to the poll interval.

### 6.3 Runner registration

- **Every runner is a repo-level JIT runner:**
  `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` with:

  | Field | Value |
  |---|---|
  | `name` | `crew-<deployment id>-<box name>-<vm suffix>`. `<vm suffix>` is the last 10 hex characters of the VM's UUID (its random bits). Box names are DNS labels of at most 40 characters, so a runner name is at most 61. |
  | `runner_group_id` | `1` (the repo's default group) |
  | `labels` | the class's label key (§7.2). JIT runners get only the labels passed, and no default `self-hosted`, OS or arch labels (spike S6 confirms this). |
  | `work_folder` | `_work` |

- **The JIT config (`encoded_jit_config`) is a credential.**
  - It's held only in the memory of the VM's `Crew.VMs.Server` process
    (§9.3), and then by the agent and the guest.
  - It's never written to any table, operation row, log or telemetry
    event. The `vm.start` operation row records its args with the
    `jit_config` key removed.
  - `CrewAgent.Redactor` and the control plane's operation logging both
    drop the key.
- A JIT runner runs exactly one job and then removes itself from GitHub.
  Runners that never run a job are removed by GitHub eventually, and by
  Crew sooner (below).
- **Deleting a runner (`DELETE …/actions/runners/{id}`):**

  | Response | Meaning | What Crew does |
  |---|---|---|
  | 204 or 404 | Deleted, or already gone | Stop the VM |
  | 422 | The runner is busy: it has a job | The VM goes `busy`, and its job is fetched (§8.6) |
  | Anything else | Unknown | Retry every 30 s. Past `CREW_IDLE_MAX + 300 s`, stop the VM anyway and leave the runner to garbage collection |

- **Garbage collection** (`Crew.GitHub.RunnerGC`, every 10 minutes): for
  each repo with Crew activity in the past 24 hours, list its runners. Then
  delete every runner named `crew-<this deployment id>-*` that has:
  - no VM row, or
  - a VM row in `failed` or `destroyed`, whether the runner shows online or
    offline.

  Runners of other deployments, such as an e2e test deployment, are never
  touched.

### 6.4 Events Crew handles

| Event | What Crew does |
|---|---|
| `workflow_job` (`waiting`, `queued`, `in_progress`, `completed`) | Upsert the job (§8.2). `in_progress` and `completed` link the job to the VM named by `runner_name`. |
| `workflow_run` (`requested`, `in_progress`, `completed`) | Upsert the run attempt: name, event, branch, head SHA, PR numbers, actor, `head_repository.full_name` |
| `installation`, `installation_repositories` | Sync installations and repos (Foreman's sync, triggered by the webhook as well as on a timer) |
| `ping` | Record it for the Deployment page's webhook check |

Everything else is acknowledged and dropped.

### 6.5 Fetching more data

| Endpoint | When |
|---|---|
| `GET /repos/{o}/{r}/actions/runs/{run_id}/attempts/{n}` | A `workflow_job` arrives before its run attempt is known. This is **essential** (it drives the fork check, §19.5). |
| `GET /repos/{o}/{r}/actions/runs/{run_id}/attempts/{n}/jobs` | Reconciling jobs. Crew fetches per run attempt, never per job. |
| `GET /repos/{o}/{r}/actions/jobs/{job_id}` | Once at completion, for the final steps and conclusion; every 10 s for a job someone is watching (§16.2) |
| `GET /repos/{o}/{r}/actions/jobs/{job_id}/logs` | After completion (§16.3). It redirects to one plain-text file for the whole job. |

### 6.6 API budget

All calls go through `Crew.GitHub.Client` (Req). The client:

- **Tracks** `x-ratelimit-remaining` and `x-ratelimit-reset` per
  installation. The limit is 5,000 an hour, plus 50 per repo above 20, up
  to 12,500.
- **Limits concurrency** to 20 requests at a time per installation.
- **Paces writes:** a token bucket for POST and DELETE, at 60 a minute and
  450 an hour per installation, under GitHub's secondary limit on
  content-creating requests. JIT generation is served first. Runner DELETEs
  for reaping wait when the bucket is empty.
- **Backs off** on 403/429 with `retry-after`, or until the reset.

Calls are classed by importance:

| Class | Calls | Below 20% of budget |
|---|---|---|
| Essential | JIT config, runner delete, run fetch for the fork check, the reconciler | Always made |
| Normal | Job fetch at completion, log fetch, runner GC | Delayed until the reset |
| Optional | Watched-job step polling, PR title enrichment | Skipped |

Budget per job is about 4 calls: the JIT config, a run fetch if needed, the
job at completion, and the log. Telemetry per endpoint feeds the Deployment
page.

## 7. Labels and sizes

### 7.1 Sizes

Sizes are rows in `sizes`, inserted by a migration (not `seeds.exs`, which
doesn't run in releases) and edited on the admin page Sizes & labels.

| Name | vCPU | Memory | Disk | Notes |
|---|---|---|---|---|
| `xs` | 1 | 2 GiB | 20 GiB | linters, actionlint |
| `s` | 2 | 4 GiB | 40 GiB | |
| `m` | 4 | 8 GiB | 60 GiB | **the default** |
| `l` | 8 | 16 GiB | 100 GiB | |
| `xl` | 16 | 32 GiB | 150 GiB | |

**Rules:**
- **Names:** a lowercase DNS label of 1–12 characters. They can't be `x64`
  or `arm64`, end in `-x64` or `-arm64`, or contain `crew`.
- **`vcpus`:** 1 or an even number up to 32. That's Firecracker's rule, and
  the `vz` driver follows it too for consistency.
- **`memory_mib`:** at least 1024, a multiple of 256.
- **`disk_gib`:** 10 to 2000.
- **Exactly one size is the default.**
- **Edits** apply to VMs started afterwards.
- **Retiring** a size makes jobs that ask for it `unsatisfiable` ("size
  retired"). A size in use by VMs that aren't `destroyed` can't be deleted,
  only retired.
- **Optional limits** (`disk_iops`, `disk_bandwidth_mbps`,
  `net_bandwidth_mbps`) become rate limiters on Firecracker. `vz` ignores
  them, and the Sizes page says so.

### 7.2 Label grammar and classes

A job opts into Crew with a `runs-on` containing exactly one Crew label:

```
crew                 default size, any arch
crew-<size>          that size, any arch
crew-<arch>          default size, that arch
crew-<size>-<arch>   that size and arch            <arch> ∈ { x64, arm64 }
```

Other labels may appear next to it, from the **generic** set
`{self-hosted, linux, x64, arm64}`. `x64` or `arm64` fixes the arch, and
contradicting the Crew label's arch is unsatisfiable.

`CrewProtocol.Labels.parse(labels, sizes, aliases)` lowercases,
deduplicates and sorts the labels into the **label key**, then returns:

| Result | When |
|---|---|
| `{:ours, %{size_id, arch: :any \| :x64 \| :arm64, key}}` | Exactly one Crew label plus generic labels only, a known size, no contradiction; or an exact alias match (§7.3) |
| `:not_ours` | No Crew label and no alias match |
| `{:unsatisfiable, reason}` | More than one Crew label, a Crew label next to a non-generic label, an unknown or retired size, or contradictory arch labels |

**Classes:**
- **A class is `(repo, label key)`.** A runner for a class is registered
  with exactly the label key as its labels:
  - `runs-on: crew-m` → runner labels `[crew-m]`
  - `runs-on: [self-hosted, crew-m]` → `[crew-m, self-hosted]`
- **Jobs can be taken across classes.** GitHub gives a runner any queued
  job whose labels are all among the runner's. So a
  `[crew-m, self-hosted]` runner can also take a `[crew-m]` job, or a bare
  `[self-hosted]` job, from the same repo.
  - Crew links the VM to whatever job it actually took (§8.6).
  - The class it was booted for keeps its deficit, so the next pass places
    another VM.
  - The job page notes "taken by a runner started for `<key>`".
- **The docs recommend `runs-on: crew-<size>` alone.** Only runners with
  exactly that key can take such a job, and Crew's runners never take jobs
  outside Crew unless a workflow uses only generic labels.

### 7.3 Label aliases (migration aid)

- **An alias** maps a whole label set to a size and arch. For example,
  `{self-hosted, linux, x64}` → `m`, `x64`.
- **Matching:** a job matches when its label key equals the alias set
  exactly. Its runners are registered with exactly the alias's labels.
- **While old Docker runners are registered on the same repo,** either pool
  may take those jobs. A job taken by a non-Crew runner leaves a Crew VM
  idle, and that VM is reaped as excess (§8.5).
- **Aliased jobs** are marked in the UI with a hint to switch to `crew-*`.

### 7.4 Per-repo settings (admin, on the repo page)

| Setting | Default | Effect |
|---|---|---|
| `enabled` | true | Disabled repos' jobs are `not_ours` |
| `allowed_sizes` | all | Other sizes are `unsatisfiable` ("size not allowed for this repo") |
| `allowed_boxes` | all | Restricts placement to these boxes, e.g. pin a sensitive repo to `linux-metal` |
| `max_concurrent` | none | A cap on the repo's VMs in `requested` through `busy` |
| `fork_prs` | `refuse` | `refuse` or `allow` (§19.5) |
| `priority` | 0 | Higher is placed first (§8.4) |

Changing `enabled`, `allowed_sizes`, `fork_prs`, sizes or aliases re-parses
the repo's jobs that GitHub still has queued or waiting.

### 7.5 Helping people choose

- **Snippets:** the repo page shows a copy-ready `runs-on:` line for each
  allowed size.
- **Hints:** the job page suggests:
  - a smaller size when the last 10 runs of the same `(repo, workflow,
    job name)` all peaked under 40% of both memory and vCPU;
  - a larger one when any of them hit an OOM kill (§16.5).

## 8. Scheduling

### 8.1 The demand model

GitHub doesn't give a particular job to a particular runner. Any idle runner
whose labels include all of a job's labels can take it, and an assigned
runner that doesn't pick its job up within 60 s loses it back to the queue.
So Crew schedules **per class**:

- **`demand(class)`** = jobs of the class with `classification = ours`,
  `gh_state = queued` and `blocked_reason = null`.
- **`supply(class)`** = VMs of the class in `requested`, `starting`,
  `booted` or `idle`, with no job linked, **on a box that is online**.
- **`deficit = demand − supply`** and **`excess = supply − demand`**.

The scheduler places VMs to close deficits (§8.3) and reaps idle VMs to
close excess (§8.5). When `in_progress` names a Crew VM, that VM is linked
to that job and leaves supply, whichever job it was booted for.

### 8.2 Jobs

Each job has two independent fields:

- **`classification`** ∈ `{ours, not_ours, unsatisfiable}`, from §7.2 and
  the static checks below. It's recomputed when settings change (§7.4).
- **`gh_state`** ∈ `{waiting, queued, in_progress, completed}`. It only
  moves forward, ranked `waiting < queued < in_progress < completed`.
  - **Upserts are one conditional statement:**
    `INSERT … ON CONFLICT (github_id) DO UPDATE SET … WHERE rank(excluded.gh_state) > rank(jobs.gh_state)`,
    so concurrent webhook workers can't move a job backwards.
  - **An event for an earlier state** is recorded in `job_events` and
    otherwise ignored.
  - **The first event seen** may be any state. The row is created in that
    state.

**Static reasons for `unsatisfiable`:**
- the labels don't parse (§7.2);
- the size is retired or not allowed for the repo;
- the repo is missing an App permission Crew needs;
- the run is a fork PR on a repo with `fork_prs = refuse` (§19.5).

**`blocked_reason`, set by the scheduler on every pass:**
- A blocked job is still `queued`, isn't counted in demand, and shows its
  reason in the UI.
- The reasons are dynamic:
  - "checking fork status" (the run fetch hasn't finished)
  - "no box could ever hold this size"
  - "no boxes enrolled"
  - "no `arm64` box"
  - "the only boxes that fit are offline / draining / quarantined /
    awaiting approval"
  - "class stalled" (§8.5)
  - "repo at max_concurrent"
- These are recomputed on every pass, so a box joining unblocks them.

**What each webhook does:**
- **`waiting`** (an environment approval) is recorded and shown, and the
  job isn't counted as demand.
- **`in_progress`:**
  - with a `runner_name` that's a Crew VM: link the VM (§8.6), whatever the
    job's classification;
  - with a non-Crew runner: record it, and show "ran on `<runner_name>`".
- **`completed`:** store the conclusion, the GitHub timestamps and the
  final steps, then start the log fetch (§16.3). If it names a Crew VM,
  link the VM if it isn't linked yet.
- **`unsatisfiable` jobs** wait until GitHub completes them. GitHub fails
  jobs that stay queued for 24 hours.

### 8.3 Placement

`Crew.Scheduler` is a singleton GenServer on the control plane. Crew runs
one control plane node, as Foreman does.

**When a pass runs:** on any change to demand, supply or capacity (job
events, VM transitions, box joins and leaves, metrics that change
eligibility, settings changes). Passes are debounced to at most one every
200 ms, with at least one a second.

**A pass is a pure function,** `Crew.Scheduler.Plan.plan(snapshot) ->
[action]`. The snapshot holds jobs, VMs, boxes, box images, settings and
the latest box metrics. The GenServer applies the actions.

1. **Compute blocked reasons** (§8.2) and each class's `deficit`.
2. **Order the queued, unblocked jobs** by §8.4. In each class, the first
   `supply(class)` jobs in that order count as covered, and each remaining
   job is one **unit** to place.
3. **For each unit, in order:** pick a box (below), and add the placement
   to the snapshot before the next unit. So fairness (§8.4), capacity and
   disk are recomputed after every placement within the pass.
4. **Apply:** insert all new VM rows (`requested`) in one transaction, which
   reserves their allocation. Then start a `Crew.VMs.Server` for each. The
   server, not the scheduler, generates the JIT config and sends `vm.start`
   (§8.6), concurrently and bounded by the GitHub client's limits.
   Placement never waits on GitHub.

**Eligible boxes** for a unit are those that:
- are online, not draining, not quarantined, not `needs_approval`, and
  report `firewall_ok: true`;
- are in the repo's `allowed_boxes` (when set);
- have the right `guest_arch` (any arch for `:any`);
- **have a usable image** (below);
- **fit the size** (below);
- keep the repo under `max_concurrent`;
- are not in the class's backoff (§8.6).

**Usable image:**
- **`usable_image(box, arch)`** is the arch's **default image** (pinned,
  else the newest registered) if it's `ready` on the box. Otherwise it's
  the newest image for that arch that's `ready` on the box and was the
  default within the last two registered releases. Otherwise there's none.
- **`vm.start` always carries `usable_image(box, arch)`.**
- **Preparing images:** a box missing the default is sent
  `image.prepare` once. A failed prepare is retried after 1, 5, then 15
  minutes, never once a pass.

**Fitting a size on a box.** Every VM not yet `destroyed` counts toward its
box's allocation, whatever state it's in.

| Resource | Rule |
|---|---|
| Per-VM limits | `vcpus ≤ max_vcpus_per_vm` and `memory_mib ≤ max_memory_mib_per_vm` (from `capabilities`) |
| Memory | Never overcommitted: Σ(`memory_mib + vmm_overhead_mib`) over allocated VMs + this one ≤ `allocatable_memory_mib` |
| vCPUs | Σ `vcpus` + this one ≤ `allocatable_vcpus × cpu_overcommit` |
| Disk | `projected_free_mib − 0.5 × disk_gib × 1024 ≥ 0.15 × vm_area_mib` |
| VM count | under the box's `max_vms`, if set |

- **`projected_free_mib`** = the latest `box.metrics.vm_area_free_mib` −
  Σ(0.5 × `disk_gib` × 1024) over the box's VMs in `requested`,
  `starting` and `booted`, and over placements earlier in this pass.
  That's an expected-use estimate for sparse clones. Real exhaustion is
  handled by the disk watchdog (§12.5).
- **`vmm_overhead_mib`** is reported by the driver: 64 for Firecracker, 128
  for vz.
- **`vm_area_mib`** is the size of the clone area (§12.5).

**Ranking eligible boxes** (the first difference wins):
1. The usable image is the arch's default.
2. The lowest memory-allocation fraction after this placement (spreading
   load, so jobs get CPU headroom). This applies to every class.
3. The box that most recently ran a VM of this repo (warm cache).
4. The box name, so the result is deterministic.

**When no box is eligible,** the unit stays queued. Its job gets a
blocked reason if the cause is static to this pass, for example "no box
with 16 GiB free (largest free: 12 GiB on m3max)".

**Box capacity:**
- **Reported by the driver** in `capabilities` (§11.1): `vcpus`,
  `memory_mib`, `vm_area_mib` and the per-VM maxima.
- **Allocatable values,** which admins can override on the box page:

| Field | Default |
|---|---|
| `allocatable_vcpus` | `vcpus − reserve_vcpus` (default `reserve_vcpus` = 1) |
| `allocatable_memory_mib` | `memory_mib − reserve_memory_mib`, where `reserve_memory_mib` defaults to `2048 + ⌊0.05 × memory_mib⌋` |
| `cpu_overcommit` | 1.5 |
| `max_vms` | unset |

- **Capabilities are pinned at enrollment** (§19.2 #6). A later report that
  changes `guest_arch` or `driver`, or moves `vcpus`, `memory_mib` or
  `vm_area_mib` by more than 10%, puts the box in `needs_approval` (no
  placements) until an admin accepts it on the box page (audit-logged).

**Worked example** (a fixed test in `Crew.Scheduler.PlanTest`): 30 queued
`crew-m` jobs (4 vCPU, 8 GiB, 60 GiB) from one repo.

| Box | Reported | Allocatable | Fits m |
|---|---|---|---|
| linux-a (`linux-metal`, fc) | 24 vCPU; 65,536 MiB; vm area 768 GiB, all free | vCPU 23 × 1.5 = 34.5; memory 65,536 − (2,048 + 3,276) = 60,212 MiB | vCPU ⌊34.5/4⌋ = 8; memory ⌊60,212 / 8,256⌋ = 7; disk: with k VMs, 786,432 − 30,720k − 30,720 ≥ 117,965 → k ≤ 20 → **7** |
| m3max (`mac-vm`, fc) | 14 vCPU; 36,864 MiB; vm area 200 GiB | vCPU 13 × 1.5 = 19.5; memory 36,864 − (2,048 + 1,843) = 32,973 | vCPU 4; memory ⌊32,973 / 8,256⌋ = 3; disk: 204,800 − 30,720k − 30,720 ≥ 30,720 → k ≤ 4 → **3** |
| m1ultra (`mac-vz`) | 18 vCPU; 110,592 MiB; vm area 400 GiB | vCPU 17 × 1.5 = 25.5; memory 110,592 − (2,048 + 5,529) = 103,015 | vCPU ⌊25.5/4⌋ = 6; memory ⌊103,015 / 8,320⌋ = 12; disk: 409,600 − 30,720k − 30,720 ≥ 61,440 → k ≤ 10 → **6** |

**Result:** 16 run at once and 14 wait. Each completion frees a slot that
the next pass fills. (The Macs' figures follow §11.4 for the M1 and the
vfkit settings for the M3. The RAM numbers are examples, not
measurements.)

### 8.4 Ordering and fairness

Waiting units are ordered by, in turn:

1. The repo's `priority`, highest first.
2. The repo's **active VM count** (VMs in `requested` through `busy`),
   lowest first. This is recomputed after each placement in the pass, for
   fair share.
3. `queued_at`, oldest first.
4. GitHub job id, lowest first.

So one repo with 30 jobs gets the whole fleet when nobody else is waiting,
and two waiting repos alternate.

### 8.5 Reaping excess

- **Every pass:** for each class with `excess > 0` that has lasted
  `CREW_IDLE_GRACE` (30 s), reap up to `excess` idle VMs of the class,
  newest first. VMs still booting count toward excess. They're reaped
  only once they're idle.
- **`CREW_IDLE_MAX` (600 s):** any VM idle that long is reaped, whatever
  the demand.
- **Draining boxes:** their idle VMs are reaped on the next pass, whatever
  the demand, and booting ones once they're idle. Their supply leaves the
  class, so the plan replaces it on other boxes. Busy VMs run to
  completion. A reboot waits on this (§12.1).
- **To reap a VM:** delete its runner (§6.3), and on 204 or 404 send
  `vm.stop` (`reaped`).
- **Stalled classes:**
  - **Trigger:** two `CREW_IDLE_MAX` reaps in a row for one class, with no
    VM of that class going `busy` in between. GitHub isn't assigning that
    class's jobs to Crew's runners: the labels don't match (spike S6), the
    runner version is too old, or the job needs an approval.
  - The class becomes **stalled**: its jobs are blocked for 10, 20, 40,
    then 60 minutes (capped), with the reason "GitHub isn't assigning jobs
    to runners labelled [...]: check labels and the runner version", and
    an activity notice.
  - Any VM of the class going `busy` clears the stall.

### 8.6 VM lifecycle

**States:** `requested → starting → booted → idle → busy → finished →
destroyed`, and `failed → destroyed`.

- **Allocation:** a VM counts toward its box's allocation in every state
  except `destroyed`.
- **Timers:** each VM is owned by a `Crew.VMs.Server`, which arms the
  timers below.
- **On control plane boot,** a server is started for every VM that isn't
  `destroyed`. Its timers are recomputed from the stored timestamps.

**Transitions** (✓ = the transition happens; anything not listed is
recorded in `vm_events` and ignored):

| Event ↓ / State → | requested | starting | booted | idle | busy | finished | failed |
|---|---|---|---|---|---|---|---|
| JIT config generated, `vm.start` sent | stays (records `start_op_id`) | | | | | | |
| `op.result ok` for `vm.start` | → starting | | | | | | ignored |
| `op.result error` for `vm.start` | → failed (`start_error`), delete the runner | | | | | | |
| guest fetched payload (`vm.state booted`) | → booted | → booted | | | | | |
| `vm.state runner_listening` | → idle | → idle | → idle | | | | |
| `workflow_job.in_progress` names this VM | → busy | → busy | → busy | → busy | | | → busy (see "failed but alive") |
| `workflow_job.completed` names this VM | → finished | → finished | → finished | → finished | → finished | | → finished |
| `vm.exited` | → failed (`boot_failed`) | → failed (`boot_failed`/`crashed`) | → failed (`crashed`) | → failed (`crashed`), delete runner | → finished | → destroyed (if cleanup ok) | → destroyed (if cleanup ok) |
| box disconnects | → failed (`lost`) | delete runner: 204/404 → failed (`lost`); 422 → busy | same | same | stays busy | stays | stays |
| box revoked | → destroyed | → destroyed | → destroyed | → destroyed | → destroyed | → destroyed | → destroyed |
| join inventory doesn't list the VM | → failed (`lost`) | → failed (`lost`) | → failed (`lost`) | → failed (`lost`) | → finished | → destroyed | → destroyed |
| join inventory lists the VM as alive | | | | | | sends `vm.stop force` | sends `vm.stop force` |

**Timeouts.** A timeout first deletes the VM's runner (when one exists).
Then:
- **204 or 404:** the VM goes to the timeout's failure and gets
  `vm.stop force`.
- **422:** the runner has a job, so the VM goes `busy` and Crew fetches the
  job to link it.
- **A command for an offline box** isn't sent. The timeout is evaluated
  again when the box rejoins.

| State | Timeout | Failure |
|---|---|---|
| requested, no JIT config after | 15 s | `jit_timeout` |
| requested, no ack after `vm.start` | 30 s | `agent_timeout` |
| starting | 60 s | `boot_timeout` |
| booted | 60 s | `runner_timeout` |
| idle | §8.5 | reaped |
| busy | `deadline` (`CREW_JOB_MAX`, 6 h 15 min). GitHub allows self-hosted jobs up to 5 days, but Crew caps them. | `killed_deadline` (the agent enforces it, §10.7) |
| finished, no `vm.exited` after | 30 s grace for log flush, then `vm.stop`; 120 s later, `vm.stop force` | — |
| failed, alive | `vm.stop force` every 60 s until `vm.exited` | — |

**Failed but alive:** a VM that timed out may still be running, for example
after a lost ack. Its runner was deleted first, so it can't take a new
job. If an `in_progress` names it anyway (the runner took a job before the
delete landed), it goes to `busy` and is kept, and the force stop is
cancelled.

**`vm.start` is never resent.** After a reconnect or a control plane
restart, any VM still in `requested` gets its runner deleted and becomes
`failed`: `agent_timeout`, or `cp_restart` at boot. The scheduler places a
fresh VM with a fresh JIT config. The agent treats `vm.start` as
idempotent by `vm_id` (§10.3) all the same.

**Failure policy:**
- **Replacements:** a VM that fails before linking a job leaves its class's
  deficit open, so the next pass places a replacement.
- **Box quarantine:** a box with 3 VM failures in a row before `idle`
  (counting `boot_failed`, `boot_timeout`, `runner_timeout`, `crashed` and
  `start_error`, but not `image_not_ready`, `lost` or `cp_restart`) is
  quarantined for 5 minutes, with an activity notice. One success clears
  the count.
- **Class backoff:** a class with 5 failures in a row on any boxes backs off
  1, 2, 4… up to 300 s. The job page shows "Crew can't start runners for
  this class: <last error>".

### 8.7 Cancellations and re-runs

- **A job cancelled while queued** gets `completed` (cancelled) with no
  runner. Demand drops, and any surplus VM is reaped as excess (§8.5).
- **A re-run** creates new jobs with new ids under a new run attempt. They
  go through the normal path.
- **Cancelling a running job:**
  - GitHub stops the runner, and the job completes.
  - The runner exits and the guest powers off (§13.5). The VM goes
    `finished`, then `destroyed`.
  - If the guest doesn't power off, the `finished` timeouts stop it.

### 8.8 Reconciliation with GitHub

`Crew.Reconciler` runs on its own Oban queue (`reconcile`, concurrency 1).
Its calls are **essential** (§6.6).

**What it re-checks:**
- **Queued jobs:** each queued job is re-checked 90 s after its last event,
  then every 5 minutes, by fetching its run attempt's jobs (one call per
  run attempt, not per job). It's skipped while any webhook for the repo
  arrived within the last 5 minutes and the job itself had one within its
  check interval.
- **Busy VMs:** each `busy` VM whose job has had no event for 15 minutes,
  the same way.
- **Missed jobs:** every 5 minutes, for each enabled repo with Crew jobs in
  the last 7 days, list the queued and in-progress runs and their jobs, and
  upsert any job Crew doesn't know.

**Poll-only mode:** the missed-job sweep is the only intake. It runs every
`max(15, ⌈3600 × calls_per_sweep × active_repos ÷ (0.3 × hourly_limit)⌉)`
seconds, where `calls_per_sweep` is about 3 (two run lists plus their
jobs). Repos idle for an hour are swept every 5 minutes.

## 9. Control plane

### 9.1 Stack

Copy Foreman's stack and versions:
- Phoenix 1.8, LiveView 1.2, Bandit
- Ecto with SQLite by default or Postgres (`CREW_DB=postgres` at build
  time)
- Oban and Oban Web
- Cloak / Cloak.Ecto
- Hammer
- Req
- Boundary
- Tailwind, esbuild and heroicons
- credo, sobelow and mix_audit in CI

Use Foreman's SQLite practices: `IMMEDIATE` transactions, portable
migrations, Unix-second timestamps for metrics. `RELEASE_DISTRIBUTION=none`.

### 9.2 Contexts (Boundary-enforced)

| Context | Owns |
|---|---|
| `Crew.Accounts` | Users, sessions, roles, allowlists (copy Foreman's) |
| `Crew.GitHub` | The App, installations, the client and its budget, webhooks, redelivery, JIT configs, runners, runner GC |
| `Crew.Repos` | Repos, repo settings, the user→repo access cache (§18.3) |
| `Crew.Sizes` | Sizes, aliases, label parsing |
| `Crew.Jobs` | Run attempts, jobs, job events, steps |
| `Crew.Scheduler` | The plan, the pass loop, reaping, stalls, quarantine, backoff |
| `Crew.Boxes` | Boxes, enrollment, capabilities and pinning, overrides, drain, approval |
| `Crew.Agents` | Agent channel, signed connect, operations and op_ids (copy Foreman's) |
| `Crew.VMs` | VM rows, `Crew.VMs.Server`, VM events |
| `Crew.Images` | Guest images, signatures, mirroring, per-box state |
| `Crew.Caches` | Cache config, tokens, stats |
| `Crew.Logs` | Log files, segments, gap handling, final-log fetch |
| `Crew.Metrics` | Box, VM and job metrics; pruning; bucketed reads (copy Foreman's) |
| `Crew.Activity`, `Crew.Audit`, `Crew.Updates`, `Crew.Settings` | Copy Foreman's |

### 9.3 Processes

| Process | What it does |
|---|---|
| `Crew.Scheduler` | Singleton GenServer (§8.3). It snapshots from the database, so a restart loses nothing. |
| `Crew.VMs.Server` | One per VM that isn't `destroyed` (Registry plus DynamicSupervisor, started at boot and at placement). It owns the VM's state machine and timers, generates its JIT config, and holds that config until the VM leaves `requested`, when it drops it. Each transition is written in one transaction with its effects. |
| `CrewWeb.AgentChannel` and `AgentSocket` | Copy Foreman's, including the signed connect and the nonce cache |
| `CrewWeb.HookEndpoint` | §6.2 |

**Oban queues:**

| Queue | Concurrency | Jobs |
|---|---|---|
| `hooks` | 10 | webhook processing |
| `github` | 5 | final job fetch, log fetch, runner GC, enrichment |
| `reconcile` | 1 | reconciler, redelivery |
| `maintenance` | 1 | pruning |
| `default` | 5 | everything else |

**PubSub topics:**
- `jobs`, `job:<id>`, `run:<id>`
- `vm:<id>`, `vm:<id>:log`
- `boxes`, `box:<id>`
- `queue`, `repo:<id>`

Payloads on shared topics carry ids only. Each LiveView loads and filters
what it may show (§18.3).

### 9.4 Retention

| Data | Kept |
|---|---|
| Jobs, run attempts, VM rows, job and VM events | 90 days (`CREW_JOB_RETENTION_DAYS`). Each job keeps at most 500 guest-sourced `job_events`. |
| Logs | 30 days (`CREW_LOG_RETENTION_DAYS`), and at most `CREW_LOG_MAX_GIB` in total, oldest deleted first |
| `box_metrics`, `vm_metrics`, `cache_stats` | 7 days (copy Foreman's `PruneMetrics`) |
| Webhook deliveries | 7 days |
| Audit log | Forever |

## 10. Agent and protocol

### 10.1 Structure and state

| Module | Basis | Notes |
|---|---|---|
| `CrewAgent.Connection` | Foreman's `connection.ex` | Slipstream, signed connect, backoff, `wss://` only |
| `CrewAgent.Identity` | Foreman's `identity.ex` | `${CREW_DATA_DIR}/agent/identity.json` (0600) |
| `CrewAgent.Ops` / `Outbox` | Foreman's `ops.ex` / `outbox.ex` | op_id dedup, results resent after reconnect |
| `CrewAgent.Updater` | Foreman's `updater.ex` | Plus darwin and launchd (§20.2) |
| `CrewAgent.HostMetrics` | Foreman's `host_metrics.ex` | Linux `/proc`; darwin via `sysctl`/`vm_stat`/`df` |
| `CrewAgent.Redactor` | Foreman's `redactor.ex` | Drops `jit_config` and guest tokens |
| `CrewAgent.VMs` | new | DynamicSupervisor of `CrewAgent.VM`, one per VM |
| `CrewAgent.GuestAPI` | new | §13.4 |
| `CrewAgent.Images` | new | Download, verify, convert, LRU eviction |
| `CrewAgent.Net` | new | Leases, nft pairs (through `crew-vmctl`) |
| `CrewAgent.Logs` | new | Per-VM log buffer, epochs, acks (§16.2) |
| `CrewAgent.Driver.*` | new | The behaviour; `Firecracker`, `VZ`, `Null` (dev only) |

**All agent state lives under `${CREW_DATA_DIR}`**: `/srv/crew` on Flatcar,
`/Library/Application Support/Crew` on macOS.

| Path | Contents |
|---|---|
| `agent/identity.json` | The ed25519 key (0600) |
| `agent/releases/<version>/`, `agent/current`, `agent/previous`, `agent/update-pending` | Agent releases and update state (Foreman's layout) |
| `agent/env` | Agent configuration (0600) |
| `images/<image_id>/` | `kernel`, `rootfs.ext4` (read-only), `manifest.json`, `manifest.sig` |
| `vms/<vm_id>/` | `vm.json`, `guest.json`, `rootfs.ext4` (the clone), `console.log`, `fc.json` or `vz.json`, `fc.log`, `fc.metrics`, `exited.json`, `ctl.sock` (vz), `guest.sock` (vz) |
| `jail/` | Jailer chroots (Linux) |
| `cache/` | crew_cache's store (Linux boxes) |

Nothing Crew writes lives on the Flatcar OS disk. Replacing the OS disk
(reprovisioning, §12.2) keeps the box's identity, its agent and its images.

### 10.2 Enrollment

Copy Foreman's flow: an admin creates a single-use join token (32 random
bytes, stored hashed, valid for one hour). The agent generates its keypair
and registers the public key with the token.

- **Flatcar boxes:** the control plane renders the Ignition for a join
  token (§12.2). It embeds the join token, the Tailscale auth key, the
  release public key and its fingerprint, plus the GitHub release URLs
  and SHA-256s of the agent and cache tarballs. The `linux-vm` and
  `mac-vm` launchers fetch it themselves; `linux-metal`, and a
  `linux-vm` box whose VM is built by hand, download it from **Add box**.
- **`mac-vz` boxes:** the Add box page shows the steps (§20.2):
  1. download the darwin tarball from the GitHub release;
  2. verify it with the published key fingerprint;
  3. run `sudo ./install-macos.sh --url … --token …`.
- **Capabilities are pinned at enrollment** (§8.3).

### 10.3 Commands (control plane → agent)

Every command has an `op_id` (UUID) and is validated by `CrewProtocol` on
both ends. The vocabulary is fixed: there's no generic exec.

| Command | Payload | Effect |
|---|---|---|
| `vm.start` | `vm_id`, `name`, `size` {vcpus, memory_mib, disk_gib, limits}, `image` {id, version, arch, manifest_sha256}, `jit_config` (≤ 16 KiB), `labels`, `deadline` (Unix s), `log_limit_bytes`, `policy` {fork_prs} | Boot a job VM (§11.2). Idempotent by `vm_id`: a `vm_id` whose directory exists answers `ok` if its VM is alive, and `error: duplicate` if not. |
| `vm.stop` | `vm_id`, `reason`, `force`, `grace_s` (0–300) | Graceful: ask the guest (§13.5), then kill after `grace_s`. Force: kill now. |
| `vm.log.ack` | `vm_id`, `epoch`, `seq` | Lines up to `seq` are stored, so the agent may drop them |
| `vm.log.resend` | `vm_id`, `epoch`, `from_seq` | Resend lines from `from_seq`, or answer `vm.log.gone` |
| `image.prepare` | `image` {id, version, arch, kernel {url, sha256, size}, rootfs {url, sha256, size}, manifest (bytes, base64), signature} | Download, verify, convert (§13.1) |
| `image.remove` | `image_id` | Delete once no VM uses it |
| `cache.config` | `enabled_hosts` (a subset of the compiled list, §15.3), `allowlist`, `parent` {url, token, ca_pem} or null, `rotate_ca` (bool) | Update crew_cache's config (§15.8) |
| `cache.purge` | `scope`: `all`, `host:<host>` or `repo:<host>/<path>` | Purge the cache |
| `box.inventory` | none | Report VMs and images |
| `box.restart` | `boot_id`, `force` (bool) | Reboot the box through `crew-vmctl reboot` (§12.1). It answers `ok` with `already: true` if the box is on another boot. Without `force`, it answers `error: busy` while any VM is live. |
| `cachevm.restart` | `boot_id` | `mac-vz` only: restart the cache VM (§12.1) |
| `agent.update` | as Foreman's | §20.2 |
| `op.cancel` | `target_op_id` | As Foreman's |

### 10.4 Events (agent → control plane)

| Event | Payload | When |
|---|---|---|
| `op.result` | `op_id`, ok / error {code, message} | Every command |
| `vm.state` | `vm_id`, `state` ∈ {booted, runner_listening, job_started, job_finished, job_refused}, `at`, `detail` (≤ 1 KiB) | Transitions the agent or guest observes |
| `vm.exited` | `vm_id`, `reason` ∈ {poweroff, crashed, killed_deadline, killed_stop, killed_disk, boot_failed}, `exit_status`, `uptime_ms`, `cleanup` ok / error | The VMM process is gone and cleanup has run |
| `vm.log` | `vm_id`, `epoch`, `seq`, `lines` [{n, t, step_ref, text, truncated}] | Every 250 ms or 64 KiB (§16.2) |
| `vm.log.gone` | `vm_id`, `epoch`, `up_to_seq` | The lines asked for are no longer held |
| `vm.steps` | `vm_id`, `steps` [{ref, name, number, status, started_at, completed_at, conclusion}] (≤ 1000) | At most once a second |
| `vm.metrics` | `vm_id`, `t`, `cpu_pct`, `mem_used_mib`, `mem_total_mib`, `disk_used_mib`, `net_rx_bps`, `net_tx_bps`, `host_cpu_pct`, `host_rss_mib` | Every 5 s per VM |
| `box.metrics` | Host CPU, memory, swap, load, disk, `vm_area_free_mib`, `cache_used_mib`, `vms_running`, `t` | Every 5 s (Foreman's pattern) |
| `box.capabilities` | §11.1 | On join and on change |
| `box.inventory` | VMs [{vm_id, alive, since, exited: {reason, exit_status, at} or null}], images [{id, state}] | On join and on request |
| `box.reboot` | `required`, `packages` (≤ 50), `boot_id`, `can_restart`, `os_version`, and on `mac-vz` `cache_vm` {required, packages, boot_id} or null | On join and on change (copy Foreman's `box.reboot`) |
| `image.state` | `image_id`, `state` ∈ {downloading, verifying, converting, ready, failed}, `progress`, `error` | During prepare |
| `cache.stats` | Per host: hits, misses, bytes served, bytes stored; evictions; digest mismatches | Every 60 s |

**Rules** (Foreman's, plus caps):
- An agent may only report on its own box's VMs and ops. Anything else is
  refused and logged.
- A `vm.log` message is at most 256 KiB, and a line's `text` at most 64 KiB:
  cut at a UTF-8 boundary, with `truncated: true`.
- Every string field has a stated maximum in `CrewProtocol`. Out-of-range
  values are refused, not clamped, except timestamps, which are clamped to
  the VM's lifetime.

### 10.5 Protocol versions

Copy Foreman's rule: the agent reports its version and protocol version on
join, and the control plane accepts N and N−1, sending new fields only to
agents on N. Upgrade the control plane before the agents.

### 10.6 Join and reconciliation

On join the agent sends `box.capabilities` and `box.inventory`. The control
plane then applies §8.6's inventory rows:
- VMs it knows that are alive are adopted.
- VMs it has as `failed` or `destroyed` that are alive, or alive VMs it
  doesn't know, get `vm.stop force`.
- VMs it had on the box that the inventory doesn't list become `lost` or
  `finished` (§8.6).
- Images: `image.prepare` per §8.3.

### 10.7 VMs survive the agent

Agent updates happen while 6-hour jobs run, so **job VMs are never children
of the agent process:**

- **Firecracker:** each VM is a transient systemd unit, started by
  `crew-vmctl` (§10.8, §11.3).
- **vz:** each VM's `crew-vz` is a child of `crew-vzd`, a separate
  LaunchDaemon (§11.4).
- **Short commands** (image conversion, `nft` through `crew-vmctl`) run
  under MuonTrap with timeouts, as in Foreman.

**Adoption on agent start, before joining:**
1. Scan `${CREW_DATA_DIR}/vms/*`.
2. For each VM, ask the driver if it's alive (`driver.alive?/1`).
3. **Alive:**
   - re-register its guest API session from `guest.json`;
   - resume its log buffer at `log_seq` with a **new epoch**;
   - resume metrics.
4. **Alive with `payload_fetched = false`:** the JIT config is gone (it was
   only in memory), so stop it and report `vm.exited` (`boot_failed`,
   detail `agent_restart`).
5. **Dead:** run `driver.cleanup/1` and record `exited.json` for the next
   inventory.

**Deadlines** are enforced three times over:
- by the agent's per-VM timer;
- by systemd's `RuntimeMaxSec` (Firecracker) or the helper's `--deadline`
  (vz) when the agent is down;
- by the control plane's `busy` timeout.

**The updater** (§20.2) waits until no VM is in `starting` (at most 90 s)
before exiting. That keeps the window where a guest could find its payload
gone small.

### 10.8 Privilege (Linux)

**The agent runs as `_crewagent`, not root.** It serves the guest API to
hostile guests, so it holds no root powers. It has write access to
`${CREW_DATA_DIR}` except `jail/` and `cache/`, and sits in the `crewvm`
group.

Root actions go through **`crew-vmctl`**, a small Go binary:
- **Socket-activated** (`crew-vmctl.socket`, `/run/crew/vmctl.sock`, 0660
  `root:_crewagent`), with one JSON request per connection.
- **It accepts only these verbs,** each validated:

| Verb | Arguments | Does |
|---|---|---|
| `start` | `vm_id` | Re-reads `vms/<vm_id>/vm.json` and `fc.json` itself, checks every path is under `${CREW_DATA_DIR}` and every value is within limits, then `chown`s the clone to the VM's uid (0600) and runs the `systemd-run` in §11.3 |
| `stop` | `vm_id`, `force` | `systemctl stop` / `kill --signal=SIGKILL crew-vm-<vm_id>` |
| `status` | `vm_id` | Unit active state and main PID |
| `list` | none | `crew-vm-*` units |
| `tap-add` / `tap-del` | `lease_index` | Creates or removes `crewt<n>` with its gateway address, owned by the VM's uid; `disable_ipv6=1`, `rp_filter=1` |
| `pair-add` / `pair-del` | `lease_index` | Adds or removes `crewt<n> . <guest ip>` in `@vm_pairs` |
| `nft-verify` | none | Compares the loaded `inet crew` table with the shipped ruleset's hash |
| `reboot` | `boot_id`, `force` | Checks `boot_id` against `/proc/sys/kernel/random/boot_id`. Without `force`, refuses while any `crew-vm-*` unit is active. Then runs `systemd-run --on-active=5 systemctl reboot` |
| `cleanup` | `vm_id` | Removes the jail directory, the unit and the tap, idempotently |

- **No verb takes a free-form path, command or argument.**
  `vm_id` must be a UUID and `lease_index` an integer in range.

**Running crew-vmctl under systemd:**
- `crew-agent.service` runs as `User=_crewagent` with `NoNewPrivileges`,
  `ProtectSystem=strict`, `ReadWritePaths=/srv/crew/agent /srv/crew/vms
  /srv/crew/images` and `OOMScoreAdjust=-900`.
- `crew-cache.service` runs as `User=crewcache`.

On macOS the agent runs as `_crewagent` and `crew-vzd` as `_crewvm`. Neither
is root.

## 11. Drivers

### 11.1 The behaviour

```elixir
defmodule CrewAgent.Driver do
  @moduledoc "One kind of host: how this box starts, finds and stops job VMs."

  @type capabilities :: %{
          driver: String.t(),               # "firecracker" | "vz" | "null"
          driver_version: String.t(),
          guest_arch: :x64 | :arm64,
          vcpus: pos_integer(),             # what the driver can give job VMs
          memory_mib: pos_integer(),
          vm_area_mib: pos_integer(),       # size of the clone area (§12.5)
          max_vcpus_per_vm: pos_integer(),
          max_memory_mib_per_vm: pos_integer(),
          vmm_overhead_mib: pos_integer(),  # per VM, counted in allocation
          features: [atom()],               # :rate_limits, :graceful_ctrl_alt_del, ...
          virtualized: boolean(),
          hypervisor_vendor: String.t() | nil,
          firewall_ok: boolean()            # nft verified (fc); netstack self-test (vz)
        }

  @type spec :: %{
          vm_id: String.t(), vcpus: pos_integer(), memory_mib: pos_integer(),
          disk_gib: pos_integer(), limits: map(),
          image: CrewAgent.Images.prepared(),   # local kernel + rootfs paths
          clone: Path.t(),                      # already cloned (§11.2)
          boot_args: String.t(),
          net: CrewAgent.Net.lease(),
          guest_socket: Path.t() | nil,         # vz: per-VM guest API socket
          deadline: integer(),
          console_log: Path.t()
        }

  @callback capabilities() :: {:ok, capabilities} | {:error, term}
  @callback prepare_image(CrewAgent.Images.downloaded()) ::
              {:ok, CrewAgent.Images.prepared()} | {:error, term}
  @callback start(spec) :: :ok | {:error, term}
  @callback stop(vm_id :: String.t(), force :: boolean) :: :ok | {:error, term}
  @callback alive?(vm_id :: String.t()) :: boolean
  @callback list() :: {:ok, [String.t()]}
  @callback stats(vm_id :: String.t()) :: {:ok, %{cpu_pct: float, rss_mib: integer}} | {:error, term}
  @callback cleanup(vm_id :: String.t()) :: :ok      # idempotent; safe if never started
end
```

**Rules:**
- **The scheduler never sees a driver's name.** It places on capabilities
  only (§8.3).
- **Drivers never talk to the control plane.** The agent owns the protocol,
  the guest API, leases, images and logs.
- **A driver's `stats/1` is the host's view** of a VM. The guest's own view
  comes from the guest (§16.5).

### 11.2 Start sequence (agent side)

1. **Validate the spec.** If `usable_image` isn't `ready` here, fail with
   `image_not_ready`.
2. **Create the VM's directory** `vms/<vm_id>/` (0750, group `crewvm`) and
   write `vm.json`: id, name, image, size, deadline, lease index,
   created_at.
3. **Clone the rootfs** (§12.5) to `vms/<vm_id>/rootfs.ext4`.
4. **Allocate a network lease** (`CrewAgent.Net`). On Firecracker that's
   `tap-add` and `pair-add` through `crew-vmctl`. **If the pair can't be
   added, the start is aborted.**
5. **Create the guest API session:**
   - a token (32 random bytes, base64url) and a session holding the
     payload, log limit and policy;
   - `guest.json` written with sha256(token), the lease, the epoch, and
     `payload_fetched: false`;
   - on vz, the per-VM `guest.sock` created (0660, `_crewagent:crewvm`).
6. **Build the boot args** (§13.3).
7. **`driver.start(spec)`.**
8. **Reply `op.result ok`.**

**On failure** at step 3 or later: run `driver.cleanup/1`, release the
lease and the session, and reply `op.result error`. The control plane then
deletes the runner (§8.6).

### 11.3 Firecracker driver

- **Binaries:** `firecracker` and `jailer` from Firecracker's GitHub release,
  static musl builds.
  - The version is pinned (≥ 1.16.1 for 6.18 guest kernels), with the
    SHA-256 checked.
  - They're shipped inside the Linux agent tarball under `bin/`, owned by
    root, and run only through `crew-vmctl`.
- **Each VM's uid and gid** are `200000 + lease_index`, unique among live
  VMs.
- **The unit** (`crew-vmctl start` runs exactly this):

  ```
  systemd-run --unit=crew-vm-<vm_id> --collect \
    -p Type=exec -p KillMode=mixed -p TimeoutStopSec=30 \
    -p MemoryMax=<memory_mib + 256>M -p MemorySwapMax=0 -p TasksMax=1024 \
    -p CPUAccounting=yes -p RuntimeMaxSec=<deadline − now> -p OOMScoreAdjust=500 \
    -p StandardOutput=append:/srv/crew/vms/<vm_id>/console.log \
    -p StandardError=append:/srv/crew/vms/<vm_id>/fc.stderr \
    -p LogRateLimitIntervalSec=10 -p LogRateLimitBurst=1000 \
    -- /srv/crew/agent/current/bin/jailer \
         --id <vm_id> --exec-file /srv/crew/agent/current/bin/firecracker \
         --uid <uid> --gid <gid> --chroot-base-dir /srv/crew/jail \
         -- --config-file /fc.json --no-api
  ```

  **Rules for the unit:**
  - **Leave out** jailer's `--cgroup`, `--parent-cgroup`, `--daemonize` and
    `--new-pid-ns`. systemd owns every limit, and the VMM is the unit's
    process tree.
  - **Spike S10 confirms** that the unit's main PID ends up as the VMM
    (jailer `exec`s it).
  - **`--no-api`:** the whole configuration is in `--config-file`, with no
    API socket to protect. Stops go through the guest API and systemd.
    `SendCtrlAltDel` is the x86 fallback only, with `--no-api` dropped if it
    turns out to be needed (S10).
- **What `crew-vmctl` puts in the chroot:** the clone and the kernel, hard
  links on the same filesystem (`/srv/crew`), plus `fc.json`, before
  starting the unit.
- **The console log** (serial `ttyS0` or arm64's `ttyAMA0`, written to the
  unit's stdout) is capped:
  - the agent truncates `console.log` beyond 8 MiB, keeping the first 4 MiB
    and a rolling last 4 MiB;
  - the guest kernel runs with `quiet loglevel=4`;
  - crew-guest never writes job output to the console.
- **`fc.json`:**
  - `boot-source`: the kernel image and `boot_args`.
  - `drives`: `rootfs` (`is_root_device`, read-write, with `rate_limiter`
    from the size's limits).
  - `machine-config`: `vcpu_count`, `mem_size_mib`, `smt: false`.
  - `network-interfaces`: `eth0`, on the lease's tap, with the lease's MAC
    and rx/tx rate limiters.
  - `entropy`: a virtio-rng device.
  - `logger`: a regular file `fc.log`, level `Warning`, not a FIFO.
  - `metrics`: a regular file `fc.metrics`. The agent doesn't depend on its
    flush interval; `stats/1` reads the unit's cgroup (`cpu.stat`,
    `memory.current`).
- **Stopping:**
  - graceful stops go through the guest API (§13.5);
  - `force`: `crew-vmctl stop --force`.
- **Requirements** (checked at agent start, and reported as features or as
  `firewall_ok`):
  - `/dev/kvm`
  - cgroup v2
  - tun
  - nftables with the verified `inet crew` table
  - XFS with reflink at `/srv/crew`
  - systemd 252 or newer

### 11.4 VZ driver

- **`crew-vzd`:**
  - a LaunchDaemon (`/Library/LaunchDaemons/com.crew.vzd.plist`,
    `UserName=_crewvm`, `KeepAlive=true`);
  - the `crew-vz` binary run as `crew-vz daemon`;
  - it owns every job VM's helper process, so VMs outlive agent restarts.
  - **Control socket:** `/Library/Application Support/Crew/vzd.sock`, 0660
    `_crewvm:crewvm`, JSON lines.
  - **Verbs:** `start {vm_id}` (re-reads `vms/<vm_id>/vz.json` and checks
    its paths and limits), `stop {vm_id, force}`, `list`, `status {vm_id}`.
- **The per-VM helper,** `crew-vz run --config vms/<id>/vz.json --deadline <unix>`,
  is crew-vzd's child, one per VM. It:
  - builds a `VZVirtualMachineConfiguration` with:
    - `VZLinuxBootLoader`: the uncompressed arm64 `Image`, the command
      line, no initrd;
    - `cpuCount` and `memorySize` from the spec;
    - `VZVirtioBlockDeviceConfiguration` on the clone;
    - `VZVirtioEntropyDeviceConfiguration`;
    - a virtio console serial port to `console.log` (capped as in §11.3);
    - the network device of §14.3;
  - writes `exited.json` {code, reason, at} before exiting, and refuses to
    start if that file already exists. A relaunch can never reboot a used
    disk.
  - exits 0 on a clean guest stop, 2 on kill, 3 on deadline and 1 on error.
- **Sandboxing:**
  - helpers run as `_crewvm`, which can't read `agent/identity.json`
    (`_crewagent`, 0600);
  - under a `sandbox-exec` profile (`native/crew-vz/sandbox.sb`) that allows
    reading the image, writing only `vms/<vm_id>/`, connecting only to that
    VM's `guest.sock` and to the cache VM's address, and outbound
    connections;
  - spike S3 checks that the profile works with Virtualization.framework,
    and if it doesn't, the helpers run unsandboxed as `_crewvm` and
    security.md says so.
- **Signing:** `crew-vz` is ad-hoc signed in CI with
  `com.apple.security.virtualization` (§20.1). vfkit (§12.3) is Red Hat's
  signed release, pinned by SHA-256. Updates change their code
  signature, so nothing may depend on a stable signing identity. That's
  why the design avoids LaunchAgents and TCC-gated APIs.
- **Local network access** (macOS 15+): LaunchDaemons are exempt from local
  network privacy, and LaunchAgents are not. That's another reason for
  LaunchDaemons only. Spike S3 tests reaching the cache VM after a reboot
  with nobody logged in.
- **Capabilities on vz:**

  | Field | Value |
  |---|---|
  | `vcpus` | physical cores − `CREW_VZ_HOST_RESERVE_VCPUS` (default 2) |
  | `memory_mib` | physical memory − `CREW_VZ_HOST_RESERVE_MIB` (default 8192) − the memory of every vfkit VM on this Mac (read from their `hostvm/<name>.conf`) |
  | `vm_area_mib` | `CREW_VZ_VM_AREA_GIB` (default 400) × 1024. Capped at 80% of the volume's free space at agent start. |
  | `max_vcpus_per_vm` | `vcpus` |
  | `max_memory_mib_per_vm` | the framework's maximum |
  | `vmm_overhead_mib` | 128 |

### 11.5 Null driver (dev and test only)

`CrewAgent.Driver.Null` runs `crew_guest` as a local OS process against a
stub runner script. That makes the control plane, scheduler, protocol and
UI buildable without KVM.

- It's compiled only when `Mix.env() in [:dev, :test]`.
- A `:prod` release refuses it.
- The control plane refuses agents that report it unless `CREW_DEV=1`.

### 11.6 Driver conformance suite

The suite lives in `apps/crew_agent/test/conformance/` (tag
`:conformance`). It runs against `firecracker` in CI on a GitHub-hosted KVM
runner (S10), and against `firecracker` on the M3 and `vz` on the M1 before
each release. Every driver must pass every item.

**Boot and sizing**
1. Boots the current image. crew-guest fetches its payload within 60 s.
2. `nproc` equals the size's vCPUs, and `MemTotal` is within 64 MiB of its
   memory.
3. The root filesystem is `disk_gib` and writable.

**Things the guest must be able to do**

4. From the guest:
   - resolve and reach `https://github.com`;
   - pull `public.ecr.aws/docker/library/alpine:3.22` twice (the second
     pull is a cache hit in `cache.stats`);
   - `docker run --rm alpine true`;
   - `docker buildx build` on the `docker-container` driver
     `FROM public.ecr.aws/docker/library/alpine:3.22`;
   - `kind create cluster`;
   - a Node `fetch('https://ghcr.io/v2/')` and a Python
     `requests.get('https://ghcr.io/v2/')`, both with the image's default
     settings (§15.4);
   - pull a private GHCR image after `docker login` with a test token. The
     cache stores nothing for it, and the test asserts this on the store.

**Things the guest must not be able to reach**

5. The guest can't reach:
   - the uplink gateway, or any address in `blocked4` or `site4` (§14.2);
   - the site's public IP on a port the test router forwards;
   - another job VM on the same box;
   - the host VM or Mac on any address, except `10.199.0.1` on the four
     service ports;
   - the tailnet;
   - `169.254.169.254`;
   - anything over IPv6 beyond its own loopback.

   It also can't:
   - spoof another VM's address (packets are dropped before conntrack);
   - exceed 2048 tracked connections.

**Payload and stopping**

6. A second payload fetch gets 410. Another VM's token is refused.
7. A graceful `stop` powers the guest off within 10 s, through the guest
   API. `force` kills it within 2 s. Both are tested on x86_64 and arm64.

**Cleanup and survival**

8. After `cleanup/1`: no process, unit or launchd entry, tap, nft element,
   jail directory or VM directory is left.
9. Restart the agent mid-job: the VM is adopted, and logs continue with a
   new epoch and no loss after the ack point.
10. A VM past its deadline is killed while the agent is down.
11. Twenty concurrent starts all boot. Report p50 and p95 to runner
    listening.

**Hostile guests**

12. A guest that writes 100 MiB to its console leaves `console.log` at or
    under 8 MiB. A guest that floods `/v1/log`, `/v1/steps` and `/v1/state`
    is throttled (§13.4), and the control plane receives at most the
    capped rates.

## 12. Host VMs and Flatcar

### 12.1 Flatcar

- **Version:** Flatcar Container Linux, stable channel. A Crew release
  pins only the **first-boot version** in `images/flatcar/VERSION`, with
  its SHA-512 digests from Flatcar's signed `DIGESTS` files and its
  `/usr` verity hash. The launchers install that version, and Flatcar
  keeps the box current after that.
- **Verification:** Crew's release verifies the first-boot image against
  Flatcar's image-signing key, and records the digests in the release
  manifest. Later updates are Flatcar's own signed payloads, which
  update-engine verifies before applying.

**OS updates copy Foreman's model:** Flatcar downloads and applies updates
by itself, and nothing reboots a box on its own.
- **Flatcar's settings:**
  - `update-engine.service` runs as shipped, against Flatcar's update
    server. It writes each update to the other `/usr` partition, and the
    update takes effect on the next boot.
  - `/etc/flatcar/update.conf` sets `REBOOT_STRATEGY=off`, so
    `locksmithd` never reboots the box.
- **Flagging a pending update** (copy Foreman's `flatcar-update-check`):
  - `crew-flatcar-update.timer` runs every minute, as
    `/bin/sh /etc/crew-box/flatcar-update-check`.
  - When `update_engine_client -status` reports
    `UPDATE_STATUS_UPDATED_NEED_REBOOT`, it writes `/run/reboot-required`
    and adds `flatcar-<NEW_VERSION>` to `/run/reboot-required.pkgs`.
- **The Tailscale sysext** updates the same way (copy Foreman's
  `update-sysexts.sh`, Tailscale only):
  - `crew-sysext-update.timer` runs daily;
  - it runs `systemd-sysupdate -C tailscale update` against the bakery
    config in `/etc/sysupdate.tailscale.d`;
  - it flags a new version as `tailscale-<version>` in the same files.
- **The agent reports it** in `box.reboot` (§10.4): whether a reboot is
  required, the flagged packages, the kernel's boot ID, and whether the
  box can be rebooted from Crew.
- **Reboots are always started by an admin,** with **Reboot** on the box
  page. For a CI box that means drain first, then reboot:
  1. The control plane sets `reboot_requested_at` and drains the box.
     Draining means no new placements. Running and idle VMs follow the
     drain rules of §8.5: idle runners are reaped, and busy jobs run
     to completion.
  2. When the box reports no live VMs in `box.inventory`, the control
     plane sends `box.restart` with the boot ID it last saw.
  3. The agent passes the request to `crew-vmctl reboot` (§10.8). That
     verb checks the boot ID, refuses if any `crew-vm-*` unit is still
     active, and schedules `systemctl reboot` 5 s later, so the agent
     has time to answer.
  4. The box comes back on a new boot ID and rejoins. The control plane
     then clears `reboot_requested_at`, and clears the drain only if the
     reboot set it.
- **Reboot now** skips the wait. It stops the box's VMs with
  `vm.stop force` and then reboots. Confirming it shows how many jobs
  will fail, and it's audit-logged.
- **A resent `box.restart`** after the reboot finds a different boot ID
  and answers `ok` with `already: true`. It never reboots twice.
- **Host VMs:** on `mac-vm`, a guest reboot makes vfkit exit, and launchd
  starts it again (§12.3). On `linux-vm`, QEMU reboots in place.
- **Reviewing an update:** the box page shows the pending Flatcar version
  with a link to its release notes on flatcar.org. The admin reads them
  before clicking **Reboot**, in the same way they review any other
  upstream bump.
- **Rollback:** if a new version fails to boot, Flatcar's GRUB falls back
  to the previous `/usr` partition by itself. A box that comes back on the
  old version reports it, and the box page shows "the update was rolled
  back".
- **Reprovisioning** (§12.2) is for recovery only: a broken OS disk, or
  a box far behind. It isn't how a box gets updates.

**The M1's service VM and cache VM** run the same update and flag units,
but they have no agent:
- **The service VM:**
  - The flag is bind-mounted read-only into the control plane
    container, which shows "service VM needs a reboot" on **Admin →
    Boxes**.
  - **Reboot** there writes `/run/crew-host/restart`, which a root
    `crew-host-restart.path` in the VM watches (Foreman's path-unit
    pattern).
  - The control plane is down for about a minute. Agents reconnect, and
    VMs survive (§10.7).
- **The cache VM:**
  - Its management endpoint gets a read-only `GET /host`, which returns
    `reboot_required`, `packages` and `boot_id`. The vz agent reports
    them as the M1 box's `cache_vm` entry in `box.reboot`.
  - **Reboot** on the M1's box page drains the `mac-vz` box first. Then
    the agent writes `/Library/Application Support/Crew/run/restart-cachevm`.
  - A root LaunchDaemon, `com.crew.hostvm-restart`, watches that path
    with `WatchPaths`. It runs `crew-box restart --role cache`, which
    makes vfkit power the guest off cleanly while launchd starts it
    again.
  - The drain clears once the cache VM answers `GET /host` with a new
    boot ID.
- **macOS updates** on the Macs themselves are outside Crew.

**Also on every box:**

- `docker.socket`, `docker.service` and `containerd.service` are masked.
  Docker's iptables rules would break VM forwarding.
- Sysctls:
  - `net.ipv4.ip_forward=1`
  - `net.ipv6.conf.all.forwarding=0`
  - `net.ipv6.conf.default.accept_ra=0`
  - `user.max_user_namespaces=0` (the host VM needs none)
  - `vm.swappiness=0`
  - `net.netfilter.nf_conntrack_max=262144`

### 12.2 Ignition

**Add box** asks for:
- a name (DNS label, ≤ 40)
- the type (`linux-metal`, `linux-vm` or `mac-vm`)
- a Tailscale auth key, only when there's no Tailscale OAuth client (§5.3)
- for `linux-metal`, the data disk device (e.g. `/dev/sdb`); the VM
  launchers always give the data disk as `/dev/vdb`
- an optional break-glass SSH key

It creates the join token and shows the release-key fingerprint, which
the admin compares with the one in Crew's README and release notes
(§20.2). Then:
- **`linux-vm`, `mac-vm`:** it shows the launcher's one command (§12.3).
  The launcher fetches the Ignition itself.
- **`linux-metal`:** it offers the Ignition for download, and the
  `flatcar-install` command for the OS disk.
- **`linux-vm`, built by hand:** where the launcher can't run (a TrueNAS
  SCALE host, whose OS image blocks `apt`), it also offers the Ignition
  for a VM the admin makes: host CPU passthrough, UEFI, and two VirtIO
  disks, the OS disk at `/dev/vda` (`flatcar-install -d /dev/vda`) and
  the data disk at `/dev/vdb`, as the launcher's VM has them. The box
  enrolls as `linux-vm`, so it's placed as the nested box it is rather
  than as `linux-metal`.

**`POST /agent/flatcar/ignition`** (copy Foreman's) takes `join_token`,
`arch` and optional `ssh_keys[]`, and returns the Ignition with an
`X-Crew-Box: <name>` header. A bad token counts against the enrollment
rate limit. The control plane renders `images/flatcar/box.bu.eex`
(Butane) to Ignition. CI runs `ignition-validate` on the rendered
configs for every box type, as Foreman's does.

**Flatcar quirks the units must handle** (all found by Foreman's e2e
runs):
- **`/etc` is mounted `noexec`.** No unit executes a file under `/etc`
  directly: scripts there run as `/bin/sh /etc/…`, and everything else
  runs from `/srv/crew/agent/current`.
- **`/dev/console` is only the last console** (under QEMU, a VGA screen
  nobody watches). First-boot progress goes to every console in
  `/proc/consoles`, prefixed `crew-box: `, and to the journal. The
  launchers follow the serial log for those lines and print them.

**Units and files:**

| Unit or file | What it does |
|---|---|
| `srv-crew.mount` | The data disk at `/srv/crew`. A oneshot `crew-format-data.service` runs first, ordered `Before=srv-crew.mount`, and runs `mkfs.xfs -m reflink=1` only if the disk has no filesystem. |
| `/etc/systemd/network/00-crew.network` | `[Match] Name=crewt* crew0`, `[Link] Unmanaged=yes` |
| `crew-net.service` | Creates the `crew0` dummy interface with `10.199.0.1/32`, then loads `/srv/crew/agent/current/etc/nft.conf` once at boot. It's never reloaded on a timer. |
| `crew-provision.service` | Oneshot, `Restart=on-failure`, runs `/bin/sh /etc/crew-box/provision.sh` (copy Foreman's `provision.sh`): joins the tailnet with the key file and deletes it, waits for `${CREW_URL}/healthz`, then starts `crew-agent-install.service`. After enrollment it deletes `/etc/crew-box/provision.env` and `/oem/config.ign`, and prints `crew-box: enrolled`. |
| `crew-agent-install.service` | Oneshot, idempotent, `RequiresMountsFor=/srv/crew`. If `/srv/crew/agent/current` is missing, it downloads the agent and cache tarballs from the GitHub release URLs in the Ignition, checks their SHA-256 **and** their ed25519 signatures against the release key embedded in the Ignition, installs them, and writes `/srv/crew/agent/env` (0600). |
| `crew-agent.service`, `crew-agent-rollback.service` | Copy Foreman's, as `_crewagent` (§10.8) |
| `crew-vmctl.socket`, `crew-vmctl@.service` | §10.8 |
| `crew-cache.service` | Runs as `crewcache` with `AmbientCapabilities=CAP_NET_BIND_SERVICE`, `OOMScoreAdjust=-900`, `RequiresMountsFor=/srv/crew` |
| Tailscale sysext + `tailscaled.service` | The sysext from Flatcar's bakery, pinned by digest (copy Foreman's). `crew-provision` runs `tailscale up --auth-key=file:… --advertise-tags=tag:crew-box --hostname=crew-<box>`. |
| `crew-clock-sync.timer` | Every 10 s, `ConditionVirtualization=apple`, so only on VZ (copy Foreman's `clock-sync.sh`). A VZ guest's clock stops while the Mac sleeps, and the control plane refuses an agent more than 60 s off; the emulated RTC follows the Mac's clock, so it sets the time from `/sys/class/rtc/rtc0/since_epoch` when they differ by more than 2 s. |
| `/etc/crew-box/provision.env` | `CREW_URL`, `CREW_JOIN_TOKEN`, `CREW_BOX_NAME` (0600) |
| Users | `_crewagent`, `crewcache`, `crewvm` (group). The `core` user only gets the break-glass SSH key and the launcher's own key (§12.3). |

**The join token and Tailscale key in the Ignition** are single-use, and the
join token expires after an hour. If the box isn't booted within the hour,
generate a new token. On a Mac and on bare metal, Flatcar keeps the
Ignition in the OEM partition; `crew-provision` deletes it there once the
box has enrolled, so neither secret outlives enrollment on disk.

**Reprovision Ignition:** the box page offers a version with no join token
and no Tailscale key, for OS-disk replacement. It mounts the existing data
disk and starts the installed agent.
- Tailscale state lives on the data disk (`/srv/crew/tailscale`), so the
  node keeps its identity.
- On `linux-vm` and `mac-vm`, `crew-box reimage <file>` (§12.3) applies
  it. A `linux-vm` box built by hand installs it from Flatcar's live
  image instead (`flatcar-install -d /dev/vda`).

### 12.3 Launchers

Both launchers copy Foreman's (`priv/agent/vm.sh` and `priv/agent/mac.sh`
in ntodd/foreman#132), which were tested end to end on an i7-12700 and an
M4 Max. The control plane serves them at `/agent/linux-vm.sh` and
`/agent/mac-vm.sh`, built from the running release, with the pinned
Flatcar version and its digests filled in. Each is one command:

```sh
curl -fsSL https://crew.<tailnet>.ts.net/agent/linux-vm.sh | sudo sh -s -- --token cj_...
curl -fsSL https://crew.<tailnet>.ts.net/agent/mac-vm.sh   | sudo sh -s -- --token cj_...
```

**Shared behaviour:**
- **Options:** `--cpus N`, `--memory GiB`, `--disk GiB` (OS disk,
  default 12), `--data GiB` (data disk, default 200, minimum 100). Both
  disks are sparse files.
- **A bad token fails before anything is downloaded**, and a failed first
  install leaves nothing behind. The launcher fetches the Ignition first,
  passing `arch` and the public half of an SSH key it generates for
  `crew-box ssh`.
- **Flatcar** is downloaded from `<arch>-usr/<version>` on Flatcar's
  stable release server and checked against SHA-512 digests from the
  release's signed `DIGESTS` files, which the Crew release pins.
- **Running it again** updates the launcher in place and keeps the box
  and its disks. `--cpus` and `--memory` then apply from the next start.
- **It prints the box's `crew-box: ` lines** from the serial log until
  `crew-box: enrolled`, or gives up after 10 minutes and says how to
  watch it.
- **`crew-box`** manages the box afterwards: `status`, `start`, `stop`,
  `restart`, `ssh`, `logs`, `reimage <ignition>` and `uninstall --yes`.
  `reimage` is for recovery (§12.1). It stops the box, writes a fresh
  OS disk from the release's first-boot Flatcar, stages the given
  Ignition the same way as a first install, and starts the box. The
  data disk is untouched, and Flatcar then updates itself.

**`linux-vm`** (`docs/setup/linux-host-vm.md`). Copy Foreman's `vm.sh`:
- **Needs** systemd and `/dev/kvm` with nested virtualization on
  (`/sys/module/kvm_{intel,amd}/parameters/nested` is `Y` or `1`). It
  refuses otherwise and prints the `modprobe` option to set. On Debian
  and Ubuntu it installs `qemu-system-x86` (or `qemu-system-arm`),
  `ovmf` (or `qemu-efi-aarch64`) and `bzip2` if missing.
- **`crew-box.service`** runs QEMU as the `crew-box` user (in the `kvm`
  group) with `Restart=always`, sandboxed with `ProtectSystem=strict`,
  `ProtectHome=true`, `PrivateTmp=true`, the `ProtectKernel*`,
  `ProtectControlGroups`, `ProtectClock` and `ProtectHostname` options,
  and empty `CapabilityBoundingSet` and `AmbientCapabilities`. State is in
  `/var/lib/crew-box` (0700).
- **QEMU:**
  - `-nodefaults -no-user-config -display none -cpu host -smp N -m M`;
  - OVMF as read-only pflash, plus a writable EFI variable store;
  - each disk as `virtio-blk-pci` with its own iothread,
    `num-queues=<cpus>`, `cache=none`, `discard=unmap`,
    `detect-zeroes=unmap` and `aio=io_uring`. The launcher probes
    io_uring first and falls back to `aio=threads`. (Foreman measured
    random writes 9% below the host's with io_uring and multi-queue,
    against 27% without.)
  - user-mode networking, `ipv6=off`, with only
    `hostfwd=tcp:127.0.0.1:<ssh_port>-:22` (default 2222) for
    `crew-box ssh`; `virtio-net-pci` with a fixed MAC;
  - `virtio-rng-pci`, and `virtio-balloon-pci,free-page-reporting=on` so
    memory the box frees goes back to the host;
  - the serial console to `serial.log`;
  - the Ignition through
    `-fw_cfg name=opt/org.flatcar-linux/config,file=<path>`. The image
    isn't touched.
- **The gateway, `10.0.2.2`, is the host's loopback.** Job VMs can't
  reach it, since `10.0.0.0/8` is in `blocked4` (§14.2), and the cache
  only uses QEMU's DNS at `10.0.2.3`. The conformance suite (§11.6) checks
  from a job VM that a listener on the host's `127.0.0.1` can't be
  reached.

**`mac-vm`, and the M1's cache VM and service VM.** Copy Foreman's
`mac.sh`, with vfkit:
- **vfkit** v0.6.4 (crc-org/vfkit), Red Hat's signed universal release
  with the virtualization entitlement, downloaded from its GitHub release
  and checked against a SHA-256 pinned in the Crew release. It's built on
  Code-Hex/vz, the same binding as `crew-vz`. A vfkit bump gets the same
  upstream review as any other pin (§20.4).
- **launchd, unlike Foreman's:** Foreman runs its Mac box as a LaunchAgent
  in the user's login session. A CI box has to come back after a power
  cut with nobody logged in, so Crew installs a LaunchDaemon per VM,
  `/Library/LaunchDaemons/com.crew.hostvm.<name>.plist`, run as root
  until S3 shows `_crewvm` works. State is in
  `/Library/Application Support/Crew/hostvm/<name>/` (root, 0700). The
  plist copies Foreman's: `RunAtLoad`, `KeepAlive=true`,
  `ThrottleInterval=5`, `ExitTimeOut=60`, `ProcessType=Interactive`.
- **vfkit's arguments:**
  - `--cpus`, `--memory`;
  - `--bootloader efi,variable-store=<dir>/efi-vars[,create]`;
  - `--device virtio-blk,path=<dir>/os.img` and
    `--device virtio-blk,path=<dir>/data.img`;
  - `--device virtio-net,nat,mac=<fixed>`;
  - `--device virtio-serial,logFilePath=<dir>/serial.log` (the previous
    boot's is kept as `serial.log.1`);
  - `--device virtio-rng`;
  - `--restful-uri unix://<dir>/rest.sock`, which `crew-box status`
    reads;
  - `--nested`, **required for `mac-vm` boxes** and not used for the
    cache and service VMs. The launcher checks first for macOS 15 or
    later and an M3 or later, and refuses with a message that names
    both. vfkit itself refuses with "nested virtualization is not
    supported".
- **Getting the Ignition in.** vfkit's `--ignition` needs vsock in the
  initrd, which Flatcar's doesn't have, and the OEM partition is btrfs,
  which macOS can't write. So, as in Foreman, a prep boot stages it:
  1. vfkit boots the image's own kernel directly (`--kernel`, an empty
     `--initrd`, 2 vCPUs, 2 GiB) with the OS disk and a read-only ISO
     made by `hdiutil makehybrid` holding the Ignition and `prep.sh`;
  2. the command line mounts `/usr` by its verity hash and runs
     `systemd.run=/usr/bin/sh /run/crewcfg/prep.sh` with
     `systemd.run_success_action=poweroff` and
     `systemd.run_failure_action=poweroff`;
  3. `prep.sh` runs `flatcar-reset --ignition-file`, adds
     `console=hvc0` to `/oem/grub.cfg`, syncs, and prints
     `crew-box: config staged`;
  4. the launcher waits up to 180 s for that line, then deletes the ISO
     and boots the box normally with EFI. The prep boot takes about 9 s.
- **Writing the OS disk:** `bunzip2 | dd conv=sparse`, then a second
  `dd conv=sparse` file to file, then `truncate`. APFS fills in most of a
  file written slowly from a pipe (5.2 GB for 0.9 GB of data); the
  second copy keeps the holes.
- **Reboots:** VZ can't reboot a guest. vfkit exits and launchd starts it
  again. On SIGTERM (unload, shutdown) vfkit asks the guest to power off,
  within the plist's `ExitTimeOut`.
- **Addresses:** the darwin agent on the M1 reads the cache VM's address
  from `/var/db/dhcpd_leases` by its MAC every 10 s, and writes it to
  `/Library/Application Support/Crew/hostvm/cachevm.ip`, which §15.6
  uses.
- **Sleep:** a Mac that sleeps pauses its VMs, and its jobs lose GitHub.
  The box reports `sleep_disabled` from `pmset -g` (`sleep` is 0), and
  the box page warns when it isn't. The docs tell the admin to run
  `sudo pmset -a sleep 0`; the installer doesn't change power settings
  itself.
- **The service VM's Butane** (`service.bu.eex`) runs:
  - Docker, plus the control plane compose project (copy Foreman's
    `docker/compose.yml`, with 4001 published);
  - the parent cache (`crew-cache.service` in parent mode, §15.7);
  - Tailscale;
  - `crew-update` (copy `foreman-update`, §20.3).
- **The cache VM's Butane** (`cachevm.bu.eex`) runs `crew-cache.service`
  in box mode for the `mac-vz` box, plus Tailscale (for the management
  endpoint), and nothing else.
- **`install-macos.sh`** on the M1 installs the cache VM and service VM
  with this same launcher code (`--role cache|service`), then the
  `mac-vz` box itself (§11).

### 12.4 Disks

| Disk | Contents |
|---|---|
| OS disk | Flatcar plus `/etc` from Ignition. Crew writes nothing else there. |
| Data disk (`/srv/crew`, XFS `reflink=1`) | Three XFS project quotas: `vms/` + `jail/` (the **clone area**, `vm_area_mib` = the quota), `cache/` (`CREW_CACHE_MAX_GIB`, default 25% of the disk), and `agent/` + `images/` (the rest). One area filling up can't starve the others. |

### 12.5 Clones and the disk watchdog

**Cloning a rootfs:**
- **Linux:** `cp --reflink=always images/<id>/rootfs.ext4 vms/<vm>/rootfs.ext4`,
  then `truncate -s <disk_gib>G`. Fails if reflink isn't supported: there's
  never a full copy.
- **macOS:** `clonefile(2)`, then `truncate`.
- **The guest grows the filesystem online** at boot (§13.5).

**The disk watchdog** (in the agent) runs every 10 s:
- **Clone area under 10% free:** report it, so placement stops (the
  scheduler reads `vm_area_free_mib`).
- **Under 5%:** kill the running VM whose clone has grown most
  (`st_blocks` × 512, the allocated size), and report `vm.exited`
  `killed_disk`. Repeat every 10 s until it's back above 5%.
- **The image area under 10% free:** evict unused images, least recently
  used first, never the box's usable or default image.
- **The cache** evicts within its own quota (§15.3).

## 13. Guest image and guest contract

### 13.1 Guest image

The image is built in Crew's CI on a release tag, per arch (x86_64 and
aarch64), on runners of that arch.

**Inputs, all pinned:**

| Input | How it's pinned and checked |
|---|---|
| Base | `ubuntu:24.04` by digest, exported to a root filesystem |
| Ubuntu packages | from `snapshot.ubuntu.com` at the timestamp in `images/guest/packages.lock` |
| Docker Engine | Docker's apt repo, key fingerprint checked, exact versions (`docker-ce=5:<ver>`, `containerd.io=<ver>`, buildx, compose) |
| PostgreSQL clients | PGDG, key fingerprint checked, exact versions (17 and 18) |
| `actions/runner` | GitHub's release, SHA-256 checked |
| Playwright browsers | SHA-256 pinned, as `docker-runners/runners/base` does today. On arm64 only Playwright's own Chromium, because Chrome for Testing has no linux-arm64 build. |
| Kernel | kernel.org 6.18.y LTS (a Firecracker-supported guest series). The tarball's `.sign` is verified and its SHA-256 pinned. |

**The build fails** if any package resolves to a version other than the one
in `packages.lock`, and the release notes include the lock's diff.

**Packages** (exact list in `images/guest/packages.txt`):
- systemd, systemd-sysv, udev, dbus, systemd-logind, iproute2, kmod
- the base set from `runners/base`: ca-certificates, curl, git, git-lfs,
  jq, build-essential, the archivers, python3, locales, tini, etc.
- Playwright's system libraries
- the union of the per-repo images: Ruby and Erlang native deps, inotify-tools,
  the FFmpeg/x264/FDK AAC dev libraries, ffmpeg, poppler-utils, shellcheck
- `cloud-guest-utils` and `e2fsprogs`

**Services:**
- masked: apt-daily, apt-daily-upgrade, unattended-upgrades,
  `systemd-networkd-wait-online`, motd-news;
- `docker.service` and `containerd.service` are installed but disabled.
  crew-guest starts them after writing their config.

**The user:** `runner` (uid 1001), with passwordless sudo, in the `docker`
group, as on GitHub's runners.

**The runner:**
- `/home/runner/actions-runner`
- `.env` contains `ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/crew/hooks/job-started`
  (§19.5) and the variables in §13.5.

**crew-guest:** the release at `/opt/crew-guest`, plus
`crew-guest.service`.

**The kernel** (`images/guest/kernel/<arch>.config`):
- **CI checks:**
  - moby's `contrib/check-config.sh` must report no missing "Generally
    Necessary" items;
  - a Crew list must be present: `IP_PNP`, `VIRTIO_MMIO`, `VIRTIO_PCI`,
    `VIRTIO_BLK`, `VIRTIO_NET`, `HW_RANDOM_VIRTIO`, `NFT_COMPAT`,
    `NETFILTER_XT_MATCH_ADDRTYPE`, `NETFILTER_XT_MATCH_CONNTRACK`,
    `IP_NF_NAT`, `IP_NF_FILTER`, `IP_NF_TARGET_MASQUERADE`, `BPF_SYSCALL`,
    `CGROUP_BPF`, `USER_NS`, `SECCOMP_FILTER`, `BINFMT_MISC`, `FUSE_FS`,
    `TUN`, `VXLAN`, `OVERLAY_FS`, `BRIDGE`, `VETH`, `EXT4_FS`;
  - on x86_64 also `SERIO_I8042` and `KEYBOARD_ATKBD`;
  - on arm64 also `INPUT_EVDEV` and `KEYBOARD_GPIO`, for the power button.
- **Output:** `vmlinux` on x86_64; an uncompressed `Image` on arm64 (both
  Firecracker and VZ boot it).
- **`CONFIG_VIRTIO_BALLOON` off.**

**The root filesystem:** `rootfs.ext4`, built with
`mkfs.ext4 -L crewroot -O ^has_journal -d <tree>`, then `e2fsck -f`.

**Artifacts per arch:**
- `crew-guest-<version>-<arch>.manifest.json`, containing:
  - version and arch;
  - the kernel's and rootfs's SHA-256 and sizes;
  - `runner_version`, `docker_version`;
  - the hash of `packages.lock`;
  - `disable_update: true`.
- `.kernel`
- `.rootfs.ext4.zst`
- `.manifest.sig`: ed25519 over the manifest file's exact bytes, with the
  release key.
- **CI fails** if the compressed rootfs is over 2 GiB, so it fits a GitHub
  release asset.

**Images on boxes:** §8.3 (usable and default) and §20.4 (rollout).
`image.prepare`:
1. downloads from the control plane, which mirrors the release assets as
   Foreman does for agents;
2. verifies the signature over the manifest, and the SHA-256s of what it
   downloaded against the manifest;
3. decompresses;
4. sets `rootfs.ext4` to 0444;
5. reports `ready`.

The agent keeps the usable and default images, plus the newest other one.

**Runner version freshness:** GitHub stops giving jobs to runners too far
behind the latest `actions/runner` release. Spike S9 records the window.
- The control plane checks the latest release daily.
- The Images page warns at 14 days behind and alerts at 21.
- Releases bump the runner (§20.4).

### 13.2 Guest network

- **`eth0`:** a static IPv4 address from the kernel's `ip=` argument:
  `<guest>/30`, gateway `<gw>`.
- **IPv6:** on for loopback (`::1`, which some software needs), with
  `net.ipv6.conf.eth0.disable_ipv6=1` set by crew-guest. The host side
  drops all IPv6 from VMs anyway (§14).
- **DNS:** `/etc/resolv.conf` is `nameserver 10.199.0.1`, written by
  crew-guest before anything else starts.
- **Docker** in the guest keeps its defaults (172.17.0.0/16 and up). Crew's
  ranges, `10.199.0.0/16` and `10.200.0.0/16`, don't overlap them.

### 13.3 Boot args

| Arch, driver | Command line |
|---|---|
| x86_64, fc | `console=ttyS0 reboot=k panic=1 pci=off quiet loglevel=4` |
| arm64, fc | `console=ttyAMA0 panic=1 quiet loglevel=4` |
| arm64, vz | `console=hvc0 panic=1 quiet loglevel=4` |

All of them add:

```
root=/dev/vda rw rootfstype=ext4
ip=<guest>::<gw>:255.255.255.252::eth0:off
crew.vm=<vm_id> crew.token=<token> crew.api=http://10.199.0.1:7777
```

**The token on the command line is readable inside the guest**
(`/proc/cmdline`). That's acceptable:
- the guest is single-tenant (everything in it is the job, which has root
  anyway);
- the token only reaches this VM's own guest API session;
- the payload is served only once.

### 13.4 Guest API

`CrewAgent.GuestAPI` is a Bandit endpoint in the unprivileged agent.
**Nothing from the guest is trusted.** The job has root and can replace
crew-guest.

**Where it listens:**
- **Firecracker boxes:** `10.199.0.1:7777`, bound to that address only.
  The source address must be the VM's lease address, and the token must
  belong to that lease's VM.
- **vz boxes:** one Unix socket per VM (`vms/<vm_id>/guest.sock`).
  `crew-vz` forwards the guest's `10.199.0.1:7777` traffic to it as raw
  bytes, so the socket identifies the VM, and the token must match it.

**Auth:** `Authorization: Bearer <token>`. Unknown or mismatched tokens get
401, at most 10 a minute per source, then the source is dropped for 60 s.

**Connections:** at most 4 at once per VM, a 10 s read timeout, a 5 s
header timeout.

| Method, path | Body | Response | Limits |
|---|---|---|---|
| `GET /v1/payload` | none | `{jit_config, ca_pem, policy: {fork_prs, repo_full_name}, size, labels}` | **Once**. Afterwards 410, recorded as `vm.state` detail `payload_refetch`. |
| `POST /v1/state` | `{state, at, detail}` | 204, or `{"stop": true}` once a stop is requested | Each state once, forward only, at most 20 per VM. `job_refused` is allowed after `job_started`. |
| `POST /v1/steps` | `{steps: [...]}` (≤ 1000, ≤ 256 KiB) | 204 or `{"stop": true}` | At most 2 a second. The agent forwards at most 1 `vm.steps` a second, coalesced. |
| `POST /v1/log` | NDJSON lines `{t, step_ref, text}` | 204, 413 or `{"stop": true}` | ≤ 1 MiB per request, ≤ 8 requests a second. The VM's total is capped at `log_limit_bytes` (default 100 MiB). Past it: 413, and the agent appends a single truncation marker. |
| `POST /v1/metrics` | `{t, cpu_pct, mem_used_mib, mem_total_mib, disk_used_mib, net_rx_bytes, net_tx_bytes}` | 204 or `{"stop": true}` | At most 1 every 2 s |
| `GET /v1/control` | none | Long poll (≤ 30 s): `{"stop": true}` or 204 | 1 open at a time |

**Validation** is `CrewProtocol.Guest`:
- unknown fields are dropped;
- strings are capped;
- `step_ref` must match `^[a-zA-Z0-9_-]{1,64}$`;
- timestamps are clamped to the VM's lifetime.

**Trust:**
- **Guest data is shown, never trusted for decisions.** Lifecycle comes from
  the VMM (the agent), and job truth from GitHub.
- **Three guest signals do affect lifecycle,** and a lying guest only hurts
  its own VM with them:
  - `runner_listening` (booted → idle; the VM is still reaped if no job
    links);
  - `job_finished` (30 s grace, then stop);
  - `job_refused` (§19.5).

### 13.5 crew-guest

- **What it is:** `apps/crew_guest`, an Elixir release with ERTS bundled,
  at `/opt/crew-guest`.
- **How it starts:** `crew-guest.service` (`Type=notify`), ordered before
  Docker. It runs the BEAM with `+S 1:1 +A 1 +sbwt none`.
- **Start-up cost:** spike S7 measures it, with a target of ≤ 300 ms.

**Sequence:**
1. Parse `crew.*` from `/proc/cmdline`.
2. Write `/etc/resolv.conf` and disable IPv6 on `eth0`.
3. `resize2fs /dev/vda` in the background. Docker waits for it.
4. `GET /v1/payload`, retried every 200 ms for 60 s. On failure, power off.
5. **Install the cache CA** (§15.4):
   - write it to `/usr/local/share/ca-certificates/crew-cache.crt`;
   - run `update-ca-certificates`;
   - write `/etc/environment` and `/etc/profile.d/crew-ca.sh` with
     `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`,
     `NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/crew-cache.crt`,
     `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`;
   - write `/home/runner/actions-runner/.env` entries for the same
     variables.
6. **Configure Docker:**
   - `/etc/docker/daemon.json`: `{"log-driver": "local"}`, plus mirror
     settings if spike S8 picks mirrors;
   - `/etc/buildkit/buildkitd.toml` with the CA for the `docker-container`
     driver, documented for workflows that create their own builders;
   - start `containerd` and `docker`.
7. **Check the JIT config:** decode it, and refuse to start (reporting
   `boot_failed` detail `update_not_disabled`) unless its `.runner`
   settings have `DisableUpdate: true` (spike S9). The runner must never
   self-update in a VM.
8. **Start the runner:**
   - write the JIT config to `/run/crew/jit` (0600, `runner`);
   - start `run.sh --jitconfig "$(cat /run/crew/jit)"` as `runner`, from a
     tiny wrapper that deletes the file once the runner has read it;
   - supervise the runner process through a Port.
9. **Report** (§16.2): `runner_listening` when the runner prints
   `Listening for Jobs`, `job_started` when the worker starts, then steps
   and log lines.
10. **Metrics:** every 5 s from `/proc/stat`, `/proc/meminfo`, `statfs /`
    and `/proc/net/dev`.
11. **Control:** keep a `GET /v1/control` long poll open. On
    `{"stop": true}`, from there or from any response: send `SIGTERM` to the
    runner, flush logs for up to 10 s, then `systemctl poweroff`.
12. **When the runner exits:** report `job_finished` with its exit code,
    flush (≤ 10 s), and `systemctl poweroff`.

On x86_64, read `systemctl reboot` for `systemctl poweroff` throughout:
Firecracker x86 has no poweroff (the guest only halts and the VM keeps
running), and `reboot=k` turns the guest's reboot into Firecracker
exiting.

**When the guest API can't be reached:**
- crew-guest buffers up to 16 MiB of logs, steps and states, retrying every
  0.5–5 s, for up to 15 minutes;
- states are kept until they're delivered or the guest powers off;
- logs are dropped oldest first past the buffer, with a marker line.

**Fallbacks for a graceful stop:**
- logind `HandlePowerKey=poweroff` (VZ's `requestStop`, and Firecracker
  arm64's power button);
- `ctrl-alt-del.target` → `reboot.target` (Firecracker x86, which ends
  the VM on a reboot).

## 14. Networking and isolation

### 14.1 Addresses (per box)

| Range | Use |
|---|---|
| `10.199.0.1/32` on `crew0` (dummy) | The service address: guest API `:7777`, cache `:443` and `:80` (`/healthz` only), DNS `:53` (UDP and TCP). Every service binds to this address only. |
| `10.200.0.0/16` | VM links: one /30 per lease (`.1` gateway on the tap, `.2` guest). 16,384 leases. |

Both ranges are configurable (`CREW_SERVICE_IP`, `CREW_VM_NET`). The agent
refuses to start if either overlaps the host VM's addresses or routes.

### 14.2 Firecracker boxes

**Taps:**
- one per VM, `crewt<lease_index>`, created by `crew-vmctl tap-add`;
- owned by the VM's uid;
- `<gw>/30` on it;
- `disable_ipv6=1` and `rp_filter=1`;
- systemd-networkd never manages it (§12.2);
- taps aren't bridged.

**The nftables ruleset:** `etc/nft.conf`, shipped in the agent tarball and
loaded once at boot by `crew-net.service`. `$UPLINK` is filled in at load
time.
- **Rules match interfaces statically** (`"crewt*"`). The only set the
  agent changes at runtime is `vm_pairs`, through `crew-vmctl`, and an
  empty `vm_pairs` drops everything from VMs. It fails closed.
- **The agent checks the loaded table** (`crew-vmctl nft-verify`) at start
  and every 60 s. On a mismatch it reports `firewall_ok: false`, which
  makes the box ineligible (§8.3).

```
table inet crew {
  set vm_pairs  { type ifname . ipv4_addr; }                       # crewt<n> . guest ip
  set blocked4  { type ipv4_addr; flags interval;
                  elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
                               169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24,
                               192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15,
                               198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4,
                               240.0.0.0/4, 255.255.255.255/32 } }
  set site4     { type ipv4_addr; flags interval; }               # filled by crew-net (below)
  set ct_new    { type ipv4_addr; flags dynamic; size 65536; }

  chain pre {                                   # before conntrack
    type filter hook prerouting priority raw; policy accept;
    iifname "crewt*" meta nfproto ipv6 drop
    iifname "crewt*" meta l4proto != { tcp, udp, icmp } drop
    iifname "crewt*" iifname . ip saddr != @vm_pairs drop          # anti-spoofing, fail-closed
    iifname "crewt*" accept
    iifname "lo" accept
    ip daddr { 10.199.0.1, 10.200.0.0/16 } drop                    # Crew ranges: VMs only
  }

  chain input {
    type filter hook input priority filter; policy accept;
    iifname "crewt*" ct state new add @ct_new { ip saddr ct count over 2048 } drop
    iifname "crewt*" ip daddr 10.199.0.1 tcp dport { 53, 80, 443, 7777 } accept
    iifname "crewt*" ip daddr 10.199.0.1 udp dport 53 accept
    iifname "crewt*" icmp type { echo-request } limit rate 10/second accept
    iifname "crewt*" drop                                           # nothing else on the host VM
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
    iifname "crewt*" ct state new add @ct_new { ip saddr ct count over 2048 } drop
    iifname "crewt*" ip daddr @blocked4 drop                        # LAN, tailnet, metadata, VMs
    iifname "crewt*" ip daddr @site4 drop                           # this site's own addresses
    iifname "crewt*" oifname $UPLINK accept
    oifname "crewt*" ct state established,related accept
  }

  chain post {
    type nat hook postrouting priority srcnat;
    iifname "crewt*" oifname $UPLINK masquerade
  }
}
```

**How the rules are applied:**
- **CI checks the ruleset:** it runs `nft -c -f etc/nft.conf` (after
  filling in `$UPLINK`) on both architectures, and conformance item 5 tests
  its behaviour.
- **Anti-spoofing runs before conntrack,** at the raw prerouting hook, so a
  spoofed packet can't match another VM's established flow. `rp_filter` on
  each tap is a second check.
- **`site4`** blocks hairpin access to the site:
  - `crew-net` fills it at boot and every 10 minutes (its only periodic
    action, an atomic set flush and refill in one `nft -f` transaction);
  - it holds:
    - the uplink's connected subnets;
    - the site's public egress IPv4, which the control plane reports to the
      agent from the address the agent's connection came from, seen
      through the tailnet as the node's endpoint (spike S12 confirms where
      that comes from);
    - the admin's `CREW_EXTRA_BLOCKED` list (comma-separated CIDRs).
- **Forward accepts only new or established traffic from `crewt*` to
  `$UPLINK`,** and replies back to `crewt*`. VM-to-VM traffic is dropped
  three ways: there's no bridge, the destination is in `blocked4`, and only
  `$UPLINK` is accepted as an output.
- **The connection cap** of 2048 tracked connections per VM applies to
  traffic both to the host VM and through it. With
  `nf_conntrack_max=262144`, one VM can't exhaust the table for the
  others.
- **IPv6 from VMs** is dropped at prerouting, which covers Router
  Advertisements and Neighbour Discovery too. Taps have `disable_ipv6=1`
  and the host has `accept_ra=0`.

### 14.3 vz boxes

Virtualization.framework's NAT puts every VM on one shared subnet, so job
VMs don't use it. Instead, each `crew-vz` helper:

- **Attaches the VM** with `VZFileHandleNetworkDeviceAttachment` (a
  socketpair), and runs a **userspace network stack** on the other end
  (gVisor's `tcpip` netstack, vendored). Every VM gets its own network,
  with no layer 2 path to anything else.
- **Gives the guest the same `/30` view** (gateway `.1`, guest `.2`), with
  the lease from the agent. It answers ARP only for the gateway, and drops
  IPv6 and anything that isn't TCP, UDP or ICMP echo.
- **Handles `10.199.0.1`:**
  - `:7777` → the VM's `guest.sock`, forwarding bytes only;
  - `:53`, `:80`, `:443` → the cache VM (§15.6), at the address in
    `hostvm/cachevm.ip`.
- **Dials everything else itself** (outbound TCP and UDP, as the Mac), and
  refuses with RST or ICMP unreachable when either:
  - the destination is in `blocked4`, or in the `site4` list (pushed by the
    agent), **checked on the actual address dialled**; or
  - the VM already has 2048 connections open.
- **Performance:** spike S4 sets the floor at ≥ 1 Gbit/s for `docker pull`.
- **This is the vz driver's isolation boundary** (§19.4 #7), and
  conformance item 5 is its acceptance test.

### 14.4 What a job VM can reach

| Destination | Allowed |
|---|---|
| Public IPv4 internet, except this site's own addresses | Yes |
| `10.199.0.1` TCP 53, 80, 443, 7777 and UDP 53 | Yes |
| ICMP echo to `10.199.0.1` | Yes (rate-limited) |
| Anything else on the host VM or Mac | No |
| Other job VMs | No |
| LAN, tailnet, link-local, cloud metadata, the site's public IP | No |
| IPv6 (other than the guest's own loopback) | No |

## 15. Registry cache

### 15.1 Approach

Docker's `registry-mirrors` setting only covers Docker Hub, and Crew's
workflows pull from ECR Public, GHCR and others. **Spike S8 decides between
two designs.**

**Design A, mirrors (preferred if S8 passes):**
- dockerd in the guest uses per-registry mirrors through the containerd
  image store's `hosts.toml`. S8 tests both `/etc/docker/certs.d/<host>/hosts.toml`
  and `/etc/containerd/certs.d/<host>/hosts.toml`.
- The cache serves `https://10.199.0.1/v2/<upstream-host>/<repo>/…` with a
  certificate for `10.199.0.1` signed by the per-box CA.
- There's no DNS interception, so nothing else in the guest is affected.
- Clients that don't use dockerd (BuildKit's container driver, kind nodes,
  Helm) simply go upstream.

**Design B, interception (the fallback):**
- the guest's DNS resolves the intercepted hostnames to `10.199.0.1`;
- the cache terminates TLS for those names with the per-box CA (§15.4);
- other clients in the guest must trust that CA, which crew-guest sets up
  (§13.5 step 5), and conformance item 4 tests.

Everything below applies to both designs, except where it's marked.

### 15.2 crew_cache

`apps/crew_cache` is an Elixir release that runs as `crewcache`. It has
four parts:

1. **`CrewCache.DNS`:** a UDP and TCP resolver on `10.199.0.1:53`.
   - **Upstreams:** `CREW_DNS_UPSTREAMS` (default `1.1.1.1, 9.9.9.9`). It
     never uses the host VM's resolver, which could be a LAN router or
     MagicDNS.
   - **Design B only:** it answers A records for the intercepted hostnames
     with `10.199.0.1`, and AAAA for them with an empty answer.
   - **It refuses** (REFUSED):
     - `ANY` queries and zone transfers;
     - names under `.local`, `.lan`, `.internal`, `.home.arpa`,
       `.ts.net` and `.localhost`;
     - reverse lookups in private ranges.
   - **It strips** any answer record inside `blocked4` or `site4`, except
     for intercepted names.
   - **It** randomises transaction ids and source ports, caches by TTL
     (capped at 300 s, at most 5000 entries), and limits each VM to 100
     queries a second.
   - It uses `:inet_dns`.
2. **`CrewCache.Registry`:** HTTPS on `10.199.0.1:443`.
   - **Design A:** one certificate for `10.199.0.1`.
   - **Design B:** a certificate per intercepted hostname, chosen by SNI.
     The `Host` header must equal the SNI name, or the request gets 421.
   - Plain HTTP on `:80` only answers `/healthz`.
3. **`CrewCache.Store`:** a content-addressed blob store
   (`cache/blobs/sha256/<2>/<64>`), with an SQLite index (`exqlite`): size,
   last access, upstream host, repository.
4. **`CrewCache.Mgmt`:** management on `127.0.0.1:7780` (box mode on Linux),
   or on the cache VM's tailnet address with a bearer token (§15.6).

### 15.3 Hosts, the allowlist and request handling

**The list of hosts Crew knows** is compiled into the signed crew_cache
release (`CrewCache.Hosts`), with each host's upstream and its anonymous
token realm:

| Hostname (and Design A path prefix) | Upstream | Anonymous token realm |
|---|---|---|
| `registry-1.docker.io` (`docker.io`) | `registry-1.docker.io` | `auth.docker.io/token` |
| `ghcr.io` | `ghcr.io` | `ghcr.io/token` |
| `public.ecr.aws` | `public.ecr.aws` | `public.ecr.aws/token` |
| `quay.io` | `quay.io` | `quay.io/v2/auth` |
| `registry.k8s.io` | `registry.k8s.io` | none (anonymous) |
| `mcr.microsoft.com` | `mcr.microsoft.com` | none |
| `gcr.io` | `gcr.io` | `gcr.io/v2/token` |

**What admins can change:**
- **`cache.config` can only enable a subset of this list** (`enabled_hosts`)
  and edit the **cacheable allowlist**.
- **Upstreams can't be overridden,** and hosts can't be added at runtime.
  Adding a host means a Crew release.
- **The allowlist** is `<host>/<repository glob>` entries, for public
  images only.
  - Defaults: `registry-1.docker.io/library/*`,
    `public.ecr.aws/docker/library/*`, `ghcr.io/actions/*`,
    `mcr.microsoft.com/*`.
  - When an admin adds an entry, the Caches page checks that it's public by
    fetching a manifest through the anonymous flow. If that's denied, the
    entry is refused.

**Request handling** (route patterns from the OCI distribution spec):

| Request | Allowlisted repo | Not allowlisted |
|---|---|---|
| `GET/HEAD /v2/` | **Passed through to the upstream** (so clients see the real auth challenge and `docker login` really logs in) | Passed through |
| `GET/HEAD /v2/<repo>/manifests/<digest>` | The store, or an anonymous upstream fetch: verify the digest, store, serve | Passed through |
| `GET/HEAD /v2/<repo>/manifests/<tag>` | An anonymous upstream HEAD for the digest, every time (with a 60 s micro-cache keyed on `(host, repo, tag, normalised Accept)`), then served by digest from the store. `Content-Type` and `Docker-Content-Digest` are returned as the upstream sent them. | Passed through |
| `GET/HEAD /v2/<repo>/blobs/<digest>` | The store, or an anonymous upstream fetch that follows redirects, streams to the client and a temp file at once, and commits only if the SHA-256 matches | Passed through |
| Anything else (`/token`, uploads, `PUT`/`POST`/`PATCH`/`DELETE`, catalog, tag lists, referrers) | Passed through | Passed through |

**How allowlisted repos are fetched:**
- **The client's `Authorization` is ignored.** The cache fetches as its own
  anonymous client: it implements the bearer-token challenge flow against
  the host's realm, and caches anonymous tokens until they expire.
- **If the anonymous fetch fails** (any non-2xx, e.g. a private repo under
  an allowlisted glob), the original request is passed through with its
  credentials, and nothing is stored.

**Passing through** means a streaming reverse proxy to the real upstream,
over TLS verified against the system trust store:
- headers go through unchanged in both directions;
- nothing is stored;
- the cache resolves the upstream (and every redirect target) itself, and
  refuses to connect to `blocked4` or `site4` addresses.

**Limits:**
- the store's quota is `CREW_CACHE_MAX_GIB` (§12.4);
- past 95% full, it evicts least recently accessed blobs down to 85%;
- a digest mismatch is a 502 and a counter;
- identical concurrent upstream fetches are coalesced, with one connection
  pool per host.

### 15.4 TLS and the CA (per box)

**The chain:**
1. On first start, crew_cache creates a **root** key (ECDSA P-256), a root
   certificate valid for 10 years, and an **intermediate** signed by it.
2. **The intermediate** carries a critical Name Constraints extension:
   - **permitted:** the enabled intercepted hostnames (Design B), or the
     `10.199.0.1` IP (Design A);
   - **excluded:** the IP ranges `0.0.0.0/0` and `::/0` (Design B), or all
     DNS names (Design A).
3. **The root key is destroyed** immediately. Only the intermediate key is
   kept (`cache/ca/`, 0600, `crewcache`).
4. **Leaf certificates** are valid for 30 days, regenerated daily, and
   signed by the intermediate.

**What guests get:**
- the **root** certificate, in their payload, as the trust anchor;
- the intermediate is sent in each TLS handshake.

Name constraints on a non-root certificate are enforced by Go, OpenSSL,
rustls and the JDK alike. With the root key gone, nothing else can ever be
signed under that root.

**Rotation:** **Rotate CA** on the Caches page, and any change to the
enabled hosts, regenerates the whole chain. VMs started afterwards get the
new root.

### 15.5 What the cache must never do

- Store, or serve from the store, anything fetched with client
  credentials.
- Resolve a tag through the parent cache, or through anything other than
  the real upstream.
- Accept a pushed blob into the store.
- Serve a `Host` that doesn't match SNI (Design B).
- Connect to `blocked4` or `site4` addresses.
- Log `Authorization` headers or token values.

### 15.6 The `mac-vz` box

- **The cache VM** (§12.3) runs crew_cache in box mode. It listens on its
  NAT address on `:53`, `:80` and `:443`, and on its tailnet address on
  `:7780` for management (bearer `CREW_CACHE_MGMT_TOKEN`, issued by the
  control plane).
- **`crew-vz` forwards** each VM's `10.199.0.1:{53,80,443}` to the cache
  VM's NAT address, read from `hostvm/cachevm.ip`.
- **The vz agent** sends `cache.config` to the cache VM's management
  endpoint and reads the CA from `GET /ca.pem` there.
- **Why a separate cache VM:** hostile guests' TLS, HTTP and DNS input is
  never parsed in the service VM, which holds the control plane.

### 15.7 Parent cache (LAN tier, optional)

- **Where it runs:** in parent mode on the service VM, at
  `https://<service VM tailnet name>:5443/v2/<upstream host>/<repo>/…`,
  with a certificate from the control plane's internal CA. That CA is
  generated at setup, and box caches pin it for this connection only.
- **Auth:** box caches send a per-box bearer token, issued by the control
  plane and rotated weekly. The control plane pushes the valid tokens to
  the parent through its management endpoint.
- **What it's used for:** **by-digest manifest and blob fetches for
  allowlisted repos only.** A box cache asks the parent first, and goes to
  the upstream itself if the parent errors or takes more than 5 s to the
  first byte. Tag resolution never goes to the parent.
- **The box cache verifies every digest** from the parent. A compromised
  parent can only refuse service.

### 15.8 Management API

| Endpoint | Purpose |
|---|---|
| `GET /stats` | Hits, misses, bytes, evictions, mismatches |
| `POST /config` | `enabled_hosts`, `allowlist`, `parent`, `rotate_ca`, `parent_tokens` (parent mode), validated against `CrewCache.Hosts` |
| `POST /purge` | Scoped purge |
| `POST /evict` | Evict to a target |
| `GET /ca.pem` | The root certificate |
| `GET /host` | Read-only: `reboot_required`, `packages` and `boot_id` from the VM's `/run/reboot-required*` and `/proc/sys/kernel/random/boot_id`. Used for the cache VM (§12.1). |

## 16. Live logs and job telemetry

### 16.1 Sources

GitHub has no public API for streaming a running job's log. So:

| What | Where it comes from |
|---|---|
| Live log lines and step boundaries | Inside the VM (§16.2) |
| Live step names and statuses | The API, every 10 s, while someone is watching (§16.2). Otherwise the guest. |
| The final steps and conclusion | The API at completion |
| The final log | GitHub's log download, stored as the **authoritative** log (§16.3) |

### 16.2 Capture in the guest

**Log pages:** the runner's `PagingLogger` writes each step's console
output to `_diag/pages/{timelineId}_{timelineRecordId}_{n}.log`. Every line
is `<UTC ISO-8601 timestamp> <message>`, a page rolls over at 8 MB, and
finished pages are queued for upload with `deleteSource: true`. crew-guest:
- watches `_diag/pages/` with inotify (`:file_system`), and opens each page
  on `IN_CREATE`;
- reads from the open file descriptor until the page is closed and fully
  read. A deleted file stays readable through an open descriptor, so the
  uploader can't race it.
- follows pages in order of `n` within each record;
- maps each `timelineRecordId` to a `step_ref`;
- emits `{t, step_ref, text}`, with `t` from the line's prefix.

**Steps:**
- **From the guest:** the worker's diagnostic log (`_diag/Worker_*.log`,
  lines `[<time> <type> <source>]`) is parsed for timeline record
  updates: id, name, order, state, result.
  - The parser is one module, `CrewGuest.WorkerLog`, with fixtures from the
    pinned runner version.
  - A parse failure only degrades to "Step 1…n" in page order.
- **From the API, while watched:** while at least one person has the job
  page open, the control plane fetches `GET …/actions/jobs/{id}` every
  10 s. Its live `steps` (name, number, status, times) override the guest's
  names and statuses, matched by order. No viewers, no polling. It's an
  optional call (§6.6).

**Masking:** spike S5 must confirm that pages contain masked output. **If
they don't, live log capture doesn't ship.** In that case the job page
shows steps and timings while the job runs, and GitHub's log afterwards.

**Shipping lines:**
- **crew-guest → agent:** batches every 250 ms or 64 KiB.
- **Agent → control plane:**
  - The agent numbers lines (`n`, per VM) and sends `vm.log` with `epoch`
    and `seq`.
  - **The epoch is a random 64-bit value,** new each time the agent adopts
    or starts the VM, and persisted in `guest.json`.
  - **The agent keeps unacknowledged batches** (up to 32 MiB per VM, or 5
    minutes).
  - **The control plane sends `vm.log.ack`** every second.
  - **On a gap** in `seq`, it sends `vm.log.resend`. A gap that isn't
    filled within 10 s, or that's answered with `vm.log.gone`, gets a
    marker line `[N lines lost]`, and the stream continues.
  - **A new epoch** restarts `seq` tracking, and keeps line numbering
    going from the last stored `n`.

**Workflow commands** (`::group::`, `::endgroup::`, `##[group]`,
`::error …::`, `::warning …::`, `::notice …::`) are kept as text and
interpreted by the viewer (§17.6).

### 16.3 Storage

**Live capture is stored per VM:**
- `${CREW_LOG_DIR}/vm/<vm_id>/live.ndjson`, one JSON object per line
  (`n`, `t`, `step_ref`, `text`);
- a `log_segments` row (`vm_id`, `first_n`, `last_n`, `byte_offset`,
  `byte_len`) every 1000 lines;
- each batch broadcast on `vm:<id>:log`.
- **A job's live log is its linked VM's log.** The job page subscribes once
  the VM is linked, so lines that arrive before linking aren't lost.

**The final log is stored per job:**
- `${CREW_LOG_DIR}/job/<job_id>/github.ndjson`.
- **Fetch timing:** at 5 s, 15 s, 60 s and 180 s after `completed`
  (GitHub's log is often 404 at first).
- **Converting it:** the download is one plain-text file of
  timestamp-prefixed lines. Each line is assigned to a step by its
  timestamp, using the API steps' `started_at` and `completed_at`.
- **If every attempt fails,** the job keeps only the live capture, with
  `log_source: live`, and the UI says "GitHub's log wasn't available".
- **The job page shows GitHub's log once it exists,** labelled
  authoritative. The live capture stays available as "reported by the VM".

**Files stay uncompressed** until they're deleted at retention, so
`byte_offset` keeps working. Per-job and global caps are in §9.4 and
§10.3.

**Redaction:** Crew never has repo secrets. The runner masks output, and
spike S5 confirms that for pages. Access control (§18.3) protects logs.

### 16.4 Timings

| Mark | Source |
|---|---|
| `queued_at` | `workflow_job.created_at` (GitHub's clock) |
| `seen_at`, `placed_at`, `vm_started_at`, `booted_at`, `runner_listening_at` | When the **control plane** received each event (Crew's clock) |
| `started_at`, `completed_at` | `workflow_job` (GitHub's clock) |

**Phases:**

| Phase | From → to |
|---|---|
| Waiting for capacity | `seen → placed` |
| Boot | `placed → runner_listening` |
| Pickup | `runner_listening → started` |
| Run | `started → completed` |

- The phases use the **linked VM's** marks.
- A phase that comes out negative, because GitHub's and Crew's clocks
  differ or because the runner was booted for another job, is shown as 0,
  labelled "runner started for another job" where that applies.
- The repo page shows p50 and p95 for each phase over 7 days, and the
  dashboard does the same for the whole fleet.

### 16.5 Resources per job

- **Samples:** `vm_metrics` keeps 5 s samples (the guest's view plus the
  host's CPU and RSS) for 7 days.
- **Job summary**, written at completion: peak memory, peak and average
  CPU, peak disk, network bytes, and `oom`. `oom` is set when the capped
  console log shows the kernel's `Out of memory: Killed process`. That's
  display-only.
- **Right-sizing hints** come from the last 10 completed runs of the same
  `(repo, workflow, job name)` (§7.5).

## 17. UI

### 17.1 Foundations

**Copied from Foreman:**
- `core_components.ex`; `foreman_components.ex` as `crew_components.ex`;
  `layouts.ex`; `sidebar.ex`; `root.html.heex`
- `assets/css/app.css` (role-named tokens, `[data-theme=dark]`,
  self-hosted Inter); `assets/js/theme.js`; topbar; heroicons
- `charts/geometry.ex`: hand-built SVG charts, no chart library
- **Foreman's CSP:** `script-src 'self'; style-src 'self'`, with no inline
  scripts or style *attributes*.
  - Positioning through the CSSOM (`el.style.transform = …`) from
    `assets/js` is allowed by this CSP, and the log viewer uses it.
  - Oban Web keeps its one exception.

**Rules:**
- **Live:** every page updates through PubSub, and no page needs a refresh.
- **Themes:** light and dark.
- **Narrow screens:** usable at 360 px wide, with tables collapsing to cards
  as in Foreman.
- **Accessibility:**
  - status is never colour alone (always an icon and text);
  - focus states follow Foreman's;
  - the log viewer is keyboard-driven (§17.6).
- **Empty states:**
  - zero boxes: "Add your first box", linking to Add box;
  - zero repos: "Install the App on a repo";
  - no Crew jobs yet: show the `runs-on` snippet.

### 17.2 Navigation

The sidebar has:
- **Dashboard**
- **Runs**
- **Queue**
- **Repos**
- **Boxes**
- **Admin** (admins only): Images, Sizes & labels, Caches, People, Audit,
  Deployment, Oban

### 17.3 Pages

**Dashboard (`/`)**
- **Fleet strip:** a card per box with:
  - a live 30-minute CPU and memory sparkline;
  - allocated vs allocatable vCPU and memory bars;
  - VMs by size;
  - status: online, draining, rebooting, quarantined, needs approval or
    offline, plus a "reboot needed" badge;
  - firewall and virtualisation badges.
- **Counters:** running, waiting and booting jobs, each linking to a
  filtered Runs page.
- **Waiting:** the 10 longest-waiting jobs, each with its reason (§8.3).
- **Recent:** the last 20 completed jobs.
- **Charts (24 hours):** jobs started per 5 minutes, stacked by conclusion;
  p50 and p95 wait and boot times.
- **Activity feed** (Foreman's `Activity`): joins, leaves, quarantines,
  stalls, approvals, image rollouts, CA rotations, OS updates flagged,
  reboots and rollbacks.

**Runs (`/runs`)**
- **Run attempts, newest first,** with earlier attempts of the same run
  folded under the latest.
- **Columns:** status, workflow and run number, repo, branch or PR (number
  and title), short SHA, actor, a per-job state bar, duration, age.
- **Filters**, kept in the URL: repo, branch, PR, status, actor, and
  "mine".
- **Stack view:** runs grouped by branch, with superseded runs (an older
  head SHA on the same branch) collapsed under the newest. This is the view
  for a stack of 10+ PRs that keeps getting rebased.

**Run (`/runs/:id/attempts/:n`)**
- **The header:** workflow, attempt, trigger, branch or PR, SHA and commit
  message, actor, duration.
  - **Actions:** Cancel run, Re-run failed jobs, Re-run all (all need
    `can_push`, §18.3), and Open on GitHub.
- **Jobs:** shown as a graph, ordered by start time and grouped by matrix
  prefix.
- **A table** of each job's state, size, box, wait, boot and run times, and
  peak memory against its size.

**Job (`/jobs/:id`):** §17.6.

**Queue (`/queue`)**
- **Waiting units** in placement order (§8.4), with class, wait and reason.
- **Per class:** demand, supply, deficit, and stalled or backoff state.
- **A 6-hour chart** of queue depth and booting VMs.
- **Admins can change a repo's priority** from here (audit-logged).

**Repos (`/repos`)**
- **The repo list:** enabled, jobs over 7 days, success rate, p50 wait and
  run, the most-used size, the last run.
- **A repo page:**
  - settings (§7.4) and `runs-on` snippets;
  - recent runs;
  - 30-day p50/p95 duration trends per workflow and job;
  - flaky jobs (failed, then passed on a re-run of the same SHA within 7
    days);
  - right-sizing hints;
  - permissions the installation is missing;
  - for public repos: a warning when fork-PR approval isn't set to
    "require approval for all outside collaborators" (§19.5).

**Boxes (`/boxes`)** (copy Foreman's box pages)
- **The list:** a half-hour CPU and memory trend, allocated vs allocatable,
  VM counts, agent version, driver, arch, and badges.
- **A box page:**
  - **Charts,** 15 minutes to 7 days (Foreman's ranges): CPU and memory as
    the box total with each VM's share stacked beneath, then disk, load
    against cores, and cache hit rate.
  - **Running VMs:** job, repo, size, uptime, live CPU and memory. Admins
    can kill one (audit-logged).
  - **Capacity overrides** (§8.3), drain and undrain, and clearing a
    quarantine.
  - **Reboot** (copy Foreman's banner for a box waiting on a Flatcar
    update): the pending versions with links to their release notes,
    **Reboot** (drain, then reboot) and **Reboot now** (§12.1). While
    it's draining, the page shows the jobs still running. On the M1,
    the same controls for its cache VM.
  - **Approving changed capabilities** (§8.3).
  - **Images and their states;** agent and protocol versions; update state;
    capabilities; firewall and virtualisation.
  - **Reprovision Ignition** (§12.2) and **Revoke** (copy Foreman's).
  - **Add box:** a tab per type, copying Foreman's: the launcher command
    (`linux-vm`, `mac-vm`), the Ignition download (`linux-metal`, and
    `linux-vm` for a VM built by hand), or the macOS steps (`mac-vz`)
    (§10.2, §12.2).

**Admin pages**
- **Images:** the default or pinned image per arch, runner and Docker
  versions, the runner freshness warning (§13.1), rollout state per box,
  and pin and unpin.
- **Sizes & labels:** the sizes (§7.1) and aliases (§7.3), and a
  **label tester**: paste a `runs-on` value and see how it parses and which
  boxes could hold it.
- **Caches:**
  - per box: hit rate, bytes saved, store size, top images;
  - the enabled hosts, the allowlist (with the public check), the parent
    cache;
  - purge, and rotate CA.
- **People, Audit, Deployment, Oban:** Foreman's. Deployment adds:
  - the GitHub budget per installation;
  - webhook health: last delivery, failures, redeliveries, and a **Send
    ping** button;
  - the Funnel URL;
  - the release public-key fingerprint.

### 17.4 Status vocabulary

| State | Icon | Text |
|---|---|---|
| Waiting | clock | Waiting · 1m 12s · "no box with 16 GiB free" |
| Blocked | pause | Blocked · "checking fork status" |
| Booting | spinner | Booting on m3max |
| Running | pulsing dot | Running · 3m 04s |
| Succeeded | check | Succeeded in 4m 31s |
| Failed | x | Failed in 2m 10s |
| Cancelled | slash | Cancelled |
| Skipped | dash | Skipped |
| Unsatisfiable | warning | Can't run · "size xl not allowed for this repo" |
| Refused | shield | Refused · "fork PRs are refused on this repo" |
| Not Crew's | none, muted | Not a Crew job · ran on `ubuntu-24.04` |

### 17.5 Live update performance

- **Lists** use LiveView streams.
- **PubSub updates are coalesced** in each LiveView and flushed at most
  every 250 ms.
- **Pagination** is keyset (`id < cursor`), 50 rows by default.

### 17.6 The job page

**Layout:**
- **Left: the steps.** Each shows an icon, its name, a live duration, and
  "usually X" (the median for that step over the last 10 successful runs).
  The current step is highlighted, and clicking one scrolls the log to it.
- **Top: the timing bar,** with the phases from §16.4 drawn to scale.
- **Right, collapsible:**
  - live charts of the VM's CPU and memory against its size, disk and
    network;
  - placement (box, size, image, VM name);
  - after the job finishes, the resource summary and a right-sizing hint.
- **Main: the log.** A toggle switches between GitHub's log (once it
  exists) and "reported by the VM".

**The log viewer** is `assets/js/log_viewer.js`, a hook in a
`phx-update="ignore"` container. It must provide:

1. **Virtualised rendering.** Only visible lines, plus 200 above and below,
   are in the DOM, positioned through the CSSOM. That's smooth for 500k
   lines.
2. **Range fetches.** `pushEvent("lines", {source, from, to})` is answered
   with lines from the files (§16.3). The server clamps each reply to
   `to − from ≤ 5000` **and** 1 MiB.
3. **Live tail.** `push_event("append", …)` batches, coalesced per §17.5.
   - **Follow mode** is on at the bottom, and pauses when the user scrolls
     up.
   - A "Jump to live (N new)" pill appears while it's paused.
4. **ANSI.** SGR 30–37, 90–97, 40–47, 100–107, `38;5;n`, `48;5;n`,
   `38;2;r;g;b` and `48;2;r;g;b`, bold, dim, italic, underline and reset.
   - These map to classes; 24-bit colour goes to the nearest palette class.
   - Every other escape sequence is stripped.
   - **All text goes in as text nodes**, never as HTML.
5. **Groups.** `::group::` and `##[group]` up to the matching end fold.
   They start collapsed in finished steps and open in the running step.
6. **Annotations.** `::error`, `::warning` and `::notice` render as badges,
   collected in a summary bar where clicking jumps to the line.
   - **Links to files** are built only as
     `https://github.com/<repo>/blob/<sha>/<URL-encoded path>#L<line>`.
   - **URLs in log text are never auto-linked.**
7. **Search.** `/` or Ctrl-F; Enter and Shift-Enter step through hits, with
   a counter.
   - The server searches the file: `pushEvent("search", {source, q, regex,
     case})` returns line numbers, at most 10,000.
   - Regexes run through `:re` with `match_limit` and
     `match_limit_recursion` set, in a Task with a 2 s timeout, and one
     search per user at a time.
8. **Jump to first error.** On failed jobs: the first `::error`, otherwise
   the last 50 lines of the failed step.
9. **Line links.** `#L123` and `#L120-L140`; click or shift-click a line
   number.
10. **Toggles.** Timestamps (wall clock or offset from step start) and
    wrap.
11. **Copy and download.** Copy the selection without line numbers.
    **Download raw** is served with:
    - `Content-Type: text/plain; charset=utf-8`;
    - `X-Content-Type-Options: nosniff`;
    - `Content-Disposition: attachment`.
12. **Keys:**
    - `j`/`k`: steps
    - `g`/`G`: top/bottom
    - `f`: follow
    - `t`: timestamps
    - `w`: wrap
    - `e`: first error
    - `?`: help
13. **Memory.** The hook holds at most 20,000 lines, and evicted lines are
    fetched again when scrolled back.

**When GitHub's log arrives,** the view switches to it, keeping its
position by step and the line within that step.

## 18. Sign-in and authorization

### 18.1 Sign-in (identical to Foreman's)

Copy Foreman's, with `FOREMAN_` renamed `CREW_`:
- `Accounts`, the auth controller, sessions, rate limits,
  `security_headers.ex` and `client_ip.ex`.
- **Sign-in** is the App's user OAuth flow with PKCE and a `state` check.
- **Who may sign in:** `CREW_ADMINS`, `CREW_ALLOWED_USERS` and
  `CREW_ALLOWED_ORG`, with Foreman's semantics: an admin dropped from all
  three is refused, and the org 404 rule applies.
- **Re-checks** at every token refresh and every six hours.
- **Matching** by GitHub id.
- **Sessions:** 32 random bytes, stored hashed, in an encrypted, signed,
  `HttpOnly`, `SameSite=Lax` cookie, for 30 days. They're renewed at
  sign-in, and open LiveViews are dropped when a user is disabled or their
  role changes.
- **Setup:** the `/setup` one-time token, printed in the boot log.
- **The dev sign-in route** is compiled out of production builds.

### 18.2 Roles

| Role | Can |
|---|---|
| Admin | Everything |
| Member | Runs, jobs and logs of repos they can read on GitHub (§18.3), and acting on those runs with `can_push`; the dashboard, queue and boxes, with other repos masked |

### 18.3 Repo access

**Where access comes from:** the user's token, through
`GET /user/installations/{installation_id}/repositories`. It's cached in
`user_repo_access(user_id, repo_id, can_push, checked_at)`:
- **refreshed** at sign-in, at every token refresh, and every 30 minutes for
  users with a live session;
- **on an error,** the last known result is kept for up to 6 hours, and
  then access lapses.

**Enforced on every request,** including every LiveView event (`lines`,
`search`, actions) and Download raw. When a refresh removes a repo, the
user's LiveViews showing it are told to re-check. Those showing that
repo's jobs drop their subscriptions and navigate away.

**Masking for members:** anywhere fleet-wide (dashboard, queue, box pages,
activity), a job in a repo the member can't read shows as "a job in
another repo", with its size, state and timings but no repo, workflow, job
or branch names.

**Actions:** cancel and re-run need `can_push`. They're made with the
installation token and audit-logged with the requesting user.

## 19. Security model

Write `docs/security.md` in Foreman's format: what's worth stealing, the
trust boundaries, known gaps, things worth trying. Its content is this
section.

### 19.1 What's worth stealing

| Asset | Where |
|---|---|
| App private key, webhook secret, client secret | Control plane DB (encrypted) or its environment |
| User tokens | Control plane DB (encrypted) |
| JIT configs | `Crew.VMs.Server` memory → `vm.start` over WSS → agent memory → guest API (once) → `/run/crew/jit` in the guest (deleted once read) |
| Agent private keys | `${CREW_DATA_DIR}/agent/identity.json` (0600, `_crewagent`) |
| Release signing key | A GitHub Environment, protected (§20.1) |
| Cache intermediate CA keys | Each box's cache (`cache/ca/`, 0600, `crewcache`) |
| Registry credentials in transit | Jobs' `docker login` tokens, in crew_cache memory while proxying |
| Logs | Control plane data volume |

### 19.2 Boundaries and defences

1. **Job VM → host (the main boundary):**
   - KVM, and Firecracker's minimal device model;
   - the jailer: chroot, a unique uid and gid per VM, a private
     `/dev/kvm` and `tun` node, seccomp;
   - systemd limits;
   - the guest API runs in the **unprivileged** agent, and root work goes
     through `crew-vmctl`'s fixed verbs (§10.8);
   - nftables (§14.2).
   - On vz: Apple's hypervisor, plus `crew-vz` as `_crewvm` in a sandbox.
2. **Host VM → physical host:** a second hypervisor boundary on `linux-vm`
   and `mac-vm` boxes.
3. **Job VM → network:** §14.4.
4. **Job VM → cache:**
   - read-only to guests;
   - content-addressed, with digests verified;
   - nothing fetched with credentials is stored;
   - upstreams compiled in;
   - tags always resolved upstream;
   - a name-constrained intermediate with the root key destroyed (§15).
5. **Job → job:** nothing persists between jobs, and the cache is the only
   shared state, which guests can't write.
6. **Agent ↔ control plane** (Foreman's pattern):
   - signed connects with nonces;
   - the fixed command vocabulary, validated by `CrewProtocol`;
   - an agent reports only on its own box;
   - no distributed Erlang anywhere;
   - capabilities pinned at enrolment (§8.3), so a stolen key can't claim a
     huge box and draw in the fleet's jobs.
7. **Webhook endpoint:** its own listener with one route, HMAC verified, a
   size cap, deduplication, and Funnel on its port only.
8. **People ↔ control plane:** §18, with Foreman's CSP and headers.
9. **Code:** agents, caches, guest images and the helpers are all signed
   with the release key, and verified before use. A compromised control
   plane can't push code.

### 19.3 What a compromised piece can do

| Compromised | Can | Can't |
|---|---|---|
| A job | Use its VM's resources until the deadline; reach the public internet; lie in its own live log, steps and metrics; read its own (spent) JIT config | Reach other VMs, the host, the LAN, the tailnet or the site's public IP; persist; write to the cache; change GitHub's authoritative log |
| A host VM (after a VM escape and a root escalation) | Everything on that box: its VMs, their JIT configs, the cache CA, the agent key (so act as that box and receive the jobs placed on it), registry credentials passing through its cache | Change its pinned capabilities without an admin's approval; reach other boxes' VMs; sign code; read logs of jobs on other boxes |
| An agent key alone | Pose as that box and receive the JIT configs placed on it | Claim more capacity (pinned); act for other boxes |
| The control plane | Create runners on every installed repo, and change repo settings there (Administration: write); approve fork-PR runs and cancel or re-run anything (Actions: write); read all logs; change the cache allowlist | Push agent, cache, guest or helper code; redirect cache upstreams; make the cache CA vouch for other names; run commands on boxes |
| The parent cache | Refuse service | Serve wrong content (digests are verified, and tags are never resolved through it) |

### 19.4 Known gaps (start the red team here)

1. **Administration: write is broad.** GitHub has no narrower permission for
   repo-level runners. Keep the App installed only on the repos that use
   Crew, and the control plane tailnet-only. Org-level runners (Later) only
   need the org's "Self-hosted runners" permission.
2. **Public repos.** Fork-PR refusal (§19.5) is enforced in the VM before
   any job code runs, but repos must still require approval for outside
   contributors. Workflows triggered by `issue_comment` or
   `pull_request_target` run the base repo's workflow on Crew. Treat these
   triggers as running untrusted input.
3. **Egress is open** to the public internet, as on GitHub's own runners:
   abuse, mining, exfiltration of whatever the job has. Per-repo egress
   policy is Later.
4. **Live data is untrusted.** The live log, steps and metrics come from
   inside the VM. GitHub's log, once fetched, is shown as authoritative
   (§16.3).
5. **The guest API token is readable in the guest,** by design (§13.3).
6. **Nested virtualization isn't a supported Firecracker setup.** It's
   tested in production only on bare metal, and its docs allow nesting for
   development only. `linux-vm` and `mac-vm` boxes trade that for not
   needing a dedicated machine. `linux-metal` is the hardened option, and
   repos can be pinned to it (`allowed_boxes`).
7. **The vz driver's network isolation is Crew's own code:** the userspace
   stack in `crew-vz`, vendored gVisor netstack. A bug there is an
   isolation bug. It runs sandboxed as `_crewvm` (§11.4).
8. **First install.** Flatcar boxes check signatures against the release
   key embedded in the Ignition, which the control plane writes. The admin
   must compare the fingerprint shown on Add box with the published one,
   or the first install trusts the control plane. The macOS steps verify
   against the published fingerprint the admin types in.
9. **Registry credentials pass through crew_cache** in memory while being
   proxied. A compromised host VM sees them.
10. **In-memory state** (rate limits, the nonce cache) resets on restart, as
    in Foreman.
11. **Design B interception** (if S8 picks it) changes the guest's view of
    the intercepted registries. Clients that bypass the guest's trust
    settings fail closed with x509 errors; they aren't silently
    intercepted.

### 19.5 Fork PRs

**Enforcement is in the VM, before any job code runs:**
- **The hook:** the runner's job-started hook
  (`ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/crew/hooks/job-started`). It's a
  small script baked into the signed image, and GitHub fails the job if it
  exits non-zero.
- **What it reads:** `$GITHUB_EVENT_NAME`, `$GITHUB_EVENT_PATH`, and the
  repo's `fork_prs` policy from the payload (crew-guest writes the policy
  to `/run/crew/policy.json` before starting the runner).
- **When it refuses:** for events `pull_request`, `pull_request_target`,
  `pull_request_review` and `pull_request_review_comment`, it exits 1 when
  the policy is `refuse` and `pull_request.head.repo` is null or its
  `full_name` differs from `repository.full_name`.
- **When it refuses, it:**
  - prints "Crew: fork PRs are refused on this repo";
  - reports `job_refused` through the guest API;
  - exits 1.
- No job code has run at that point, so the hook can be trusted.

**The control plane also checks, as an optimisation:**
- a job whose run attempt isn't known yet is blocked with "checking fork
  status" and isn't counted as demand. The run fetch is essential (§6.6),
  and on an error the job stays blocked: it fails closed.
- **When the run is a fork PR and the policy is `refuse`:**
  - the job becomes `unsatisfiable` ("fork PRs are refused on this repo");
  - Crew cancels the run (Actions: write) and records an audit event.
  - **Cross-class taking** (§7.2) can still hand the job to an idle Crew
    runner before the cancel lands. The hook then refuses it.
- **When `in_progress` names a Crew VM for a refused job,** the control
  plane sends `vm.stop force` right away, deletes the runner, and posts an
  activity notice.

**Approval setting:** the repo page warns when a public repo doesn't require
approval for outside contributors' workflows (§17.3).

### 19.6 Things worth trying

**From a job:**
- reach the host on any non-service port, another VM, the LAN, the
  tailnet, `169.254.169.254`, the site's public IP or the Mac;
- spoof another VM's address, or inject into its flows;
- send IPv6 RAs;
- exhaust conntrack;
- fill the host disk;
- flood the console, log, steps or state endpoints;
- fetch a second payload, or use another VM's token;
- forge `job_finished` or `job_refused` for another VM.

**Against the cache:**
- serve a private image to another job: tags, `Accept` variants,
  `Authorization` reuse, Host/SNI mismatch, redirects to private
  addresses;
- get a certificate for a non-registry name;
- poison the store through the parent.

**Fork PRs:** get one past the hook: other event types, a null head repo, a
renamed fork.

**Against the control plane:**
- as an agent, act on another box's VMs, replay a connect, or report
  inflated capabilities;
- **through logs:** script injection in the UI (ANSI, HTML, `javascript:`,
  giant lines), and ReDoS through search;
- **as a member:** read a repo's logs without GitHub access, through any
  page, event, search or download, or see private repo names on the
  dashboard, queue or boxes;
- **through webhooks:** forge, replay, 25 MB payloads, or flood the
  endpoint to crowd out GitHub's deliveries.

## 20. Releases, signing and updates

### 20.1 Release (copy Foreman's `release.yml`, hardened)

A tag `vX.Y.Z` builds everything.

**Workflow hardening:**
- every action pinned by commit SHA;
- `permissions: {}` by default, granted per job;
- no third-party actions in the sign job.

**The signing key:**
- held in a GitHub Environment `release-signing` with required reviewers,
  usable only from protected `v*` tags;
- only the `sign` job uses that environment.

**Jobs:**
1. **check:** the tag equals every `mix.exs` version; the public key
   matches the one compiled into `crew_protocol`.
2. **native:** build `crew-vmctl` (linux amd64 and arm64), and `crew-vz`
   (darwin arm64, on a GitHub-hosted `macos` arm64 runner).
   - Go with `GOFLAGS=-mod=vendor GOPROXY=off`, plus `govulncheck`.
   - The darwin binaries are ad-hoc signed:
     `codesign --force -s - --entitlements native/entitlements.plist`.
3. **agents:** `crew_agent` for linux-amd64 and linux-arm64 (with
   `crew-vmctl`, the pinned `firecracker` and `jailer`, and `etc/nft.conf`),
   and for darwin-arm64 (with `crew-vz`, the launchd plists, and vfkit
   downloaded at its pinned version and checked against its SHA-256).
   - Each one is smoke-tested on its runner: it starts, prints its version,
     and runs its driver checks.
4. **cache:** `crew_cache` for linux-amd64 and linux-arm64.
5. **guest:** guest images for x86_64 and aarch64 (§13.1).
   - The conformance suite runs against `firecracker` on the x86_64 runner
     (S10).
   - The aarch64 conformance runs before release on the M3 (`mac-vm`)
     through `e2e/release-check.sh`, and its result is attached to the
     release.
6. **sign:** `mix crew.sign` (copy `mix foreman_agent.sign`) signs each
   tarball (covering version, target and SHA-256) and each image manifest
   (its exact bytes).
7. **control plane images:** GHCR, amd64 and arm64, SQLite and Postgres
   variants (copy Foreman's).
   - They contain the signed tarballs and image manifests, but not the
     large rootfs files. The control plane downloads those from the release
     when it registers them, and verifies them against the signed manifest.
8. **publish:** a GitHub release with every asset and signature, and the
   release key's fingerprint in the notes.

**Vendored Go modules:** bumped only through the review in §20.4.

### 20.2 Agent and cache updates

**Copied from Foreman:**
- the control plane registers what its image carries;
- boxes follow the newest unless pinned;
- `agent.update` is signed and checked before download;
- `current`/`previous` are swapped atomically, with an `update-pending`
  marker;
- rollback on a crash loop, or no join within 5 minutes;
- two failures of a version on a box stop it being sent again.

**Differences from Foreman:**
- **Running VMs aren't waited on.** They survive the restart (§10.7). The
  agent waits only for in-flight ops (≤ 10 minutes) and for no VM to be in
  `starting` (≤ 90 s).
- **crew_cache updates with the agent** (the same version). The agent swaps
  it and restarts `crew-cache` through `crew-vmctl` (a `restart-cache`
  verb). Its store survives. Pulls fail for ≤ 5 s during the restart, and
  Docker retries.
- **macOS:** launchd daemons with `KeepAlive` for the agent and for
  `crew-vzd`.
  - Rollback is `/Library/Application Support/Crew/agent/current/bin/crew-launch`,
    which counts starts in `agent/crashes`. After 3 starts within 120 s of
    an update, it switches `current` back to `previous`: Foreman's
    `OnFailure` unit, done for launchd.
  - `crew-vzd` is updated only when no VMs are running. The agent asks it to
    restart once its VM count reaches 0. Until then, the old `crew-vzd`
    keeps serving.
- **First install:** downloads come from the GitHub release, never from the
  control plane, and are checked against the release key (§12.2, §10.2).

### 20.3 Control plane updates

Copy Foreman's `foreman-update` as `crew-update`. The container can only ask
for a newer version. A root updater in the service VM pulls it, backs up the
data volume (database and logs), recreates the container, and rolls back if
`/healthz` doesn't answer.

### 20.4 Guest image rollout and the release cadence

**Rollout:**
- each release's images are registered, and the newest per arch becomes
  the default unless one is pinned;
- boxes prepare it in the background, and until it's `ready` they keep
  using their usable image (§8.3);
- **rolling back** means pinning the previous image.

**Cadence:** a release at least every 21 days, so the runner never goes
stale (§13.1). `docs/releasing.md` lists the bumps:
- `actions/runner`;
- Firecracker;
- the kernel's point release;
- the Ubuntu snapshot timestamp and base digest, with `packages.lock`;
- Flatcar;
- the Go modules.

**For each bump:** a **supply-chain review** of the upstream changes since
the last version. That means new dependencies, downloads, start-up scripts,
ownership changes and network calls. Record a verdict (clean / suspicious /
can't tell) in the release notes. A "suspicious" verdict blocks the bump.

## 21. Configuration reference

### 21.1 Control plane

Foreman's variables, renamed: `CREW_DB`, `CREW_ENCRYPTION_KEY`,
`SECRET_KEY_BASE`, `CREW_ADMINS`, `CREW_ALLOWED_USERS`, `CREW_ALLOWED_ORG`,
`CREW_GITHUB_*`, `PHX_HOST`, and the rest. New ones:

| Variable | Default | Meaning |
|---|---|---|
| `CREW_HOOK_PORT` | 4001 | Webhook endpoint port (§6.2) |
| `CREW_WEBHOOKS` | `on` | `off` = poll-only mode |
| `CREW_IDLE_GRACE` | 30 | §8.5 |
| `CREW_IDLE_MAX` | 600 | §8.5 |
| `CREW_JOB_MAX` | 22500 | The VM's hard deadline (6 h 15 min) |
| `CREW_LOG_LIMIT_BYTES` | 104857600 | Per VM (100 MiB) |
| `CREW_LOG_DIR` | `/var/lib/crew/logs` | |
| `CREW_LOG_MAX_GIB` | 20 | |
| `CREW_LOG_RETENTION_DAYS` | 30 | |
| `CREW_JOB_RETENTION_DAYS` | 90 | |
| `CREW_DEV` | unset | Allows the null driver and `ws://` |

`settings.public_host` (the tailnet hostname, used for the App's URLs) and
the deployment id live in the `settings` table, set on `/setup`.

### 21.2 Agent (`${CREW_DATA_DIR}/agent/env`)

| Variable | Default | Meaning |
|---|---|---|
| `CREW_URL` | required | `wss://…` |
| `CREW_BOX_NAME` | the hostname | A DNS label, ≤ 40 characters |
| `CREW_DRIVER` | `firecracker` on Linux, `vz` on macOS | |
| `CREW_DATA_DIR` | `/srv/crew` / `/Library/Application Support/Crew` | |
| `CREW_SERVICE_IP` | `10.199.0.1` | §14.1 |
| `CREW_VM_NET` | `10.200.0.0/16` | §14.1 |
| `CREW_UPLINK` | the default-route interface | §14.2 |
| `CREW_EXTRA_BLOCKED` | empty | CIDRs added to `site4` |
| `CREW_VZ_HOST_RESERVE_VCPUS` | 2 | §11.4 |
| `CREW_VZ_HOST_RESERVE_MIB` | 8192 | §11.4 |
| `CREW_VZ_VM_AREA_GIB` | 400 | §11.4 |
| `CREW_CACHE_MGMT_URL` | `http://127.0.0.1:7780` (Linux); the cache VM's tailnet URL (vz) | §15.8 |
| `CREW_CACHE_MGMT_TOKEN` | unset (Linux); issued by the control plane (vz) | |

### 21.3 crew_cache (`${CREW_DATA_DIR}/cache/env`)

| Variable | Default | Meaning |
|---|---|---|
| `CREW_CACHE_MODE` | `box` | `box` or `parent` |
| `CREW_CACHE_MAX_GIB` | 25% of the data disk | Store quota |
| `CREW_DNS_UPSTREAMS` | `1.1.1.1,9.9.9.9` | §15.2 |
| `CREW_CACHE_LISTEN` | `10.199.0.1` (Linux box); the NAT address (cache VM); the tailnet address `:5443` (parent) | |
| `CREW_CACHE_MGMT_TOKEN` | unset on Linux boxes | Required off loopback |

## 22. Data model

Ids are UUIDv7 unless stated otherwise. Timestamps are
`utc_datetime_usec`, except metrics, which use Unix seconds (as Foreman).
Defaults (sizes, the cache config singleton) come from migrations.

```
users, sessions, user_tokens, join_tokens, audit_events, settings   -- copy Foreman
settings += public_host, deployment_id, release_pubkey_fingerprint

installations(id, github_id unique, account_login, account_type, permissions map,
              suspended_at)
repos(id, installation_id, github_id unique, full_name, private, default_branch, enabled,
      allowed_sizes [string] null, allowed_boxes [uuid] null, max_concurrent int null,
      fork_prs enum(refuse, allow), priority int, archived_at)
user_repo_access(user_id, repo_id, can_push, checked_at)            pk(user_id, repo_id)

sizes(id, name unique, vcpus, memory_mib, disk_gib, disk_iops null,
      disk_bandwidth_mbps null, net_bandwidth_mbps null, is_default, retired_at)
label_aliases(id, labels [string] unique (sorted), size_id, arch enum(any, x64, arm64))

run_attempts(id, repo_id, github_run_id, run_attempt, run_number, workflow_name, event,
             head_branch, head_sha, head_commit_message, actor_login, actor_id,
             pull_requests map, head_repo_full_name, is_fork bool null, status,
             conclusion, gh_created_at, gh_updated_at)
             unique(github_run_id, run_attempt)
jobs(id, repo_id, run_attempt_id null, github_id unique, github_run_id, run_attempt,
     name, workflow_name, labels [string], label_key [string] null, size_id null, arch,
     classification enum(ours, not_ours, unsatisfiable), unsatisfiable_reason null,
     gh_state enum(waiting, queued, in_progress, completed), blocked_reason null,
     conclusion null, runner_name null, vm_id null, taken_cross_class bool,
     queued_at, seen_at, started_at, completed_at,
     steps map, log_source enum(github, live) null,
     peak_mem_mib, peak_cpu_pct, avg_cpu_pct, peak_disk_mib, net_bytes, oom bool)
job_events(id, job_id, source enum(webhook, api, guest, scheduler), kind, payload map, at)

boxes(id, name unique, type enum(linux-metal, linux-vm, mac-vm, mac-vz), driver,
      guest_arch, public_key, key_fingerprint, agent_version, protocol_version,
      capabilities map, pinned_capabilities map, needs_approval bool,
      allocatable_vcpus_override null, allocatable_memory_mib_override null,
      reserve_vcpus, reserve_memory_mib null, cpu_overcommit, max_vms null,
      draining bool, drain_reason enum(admin, reboot) null,
      reboot_required bool, reboot_packages list, boot_id null, os_version null,
      can_restart bool, reboot_requested_at null, cache_vm_reboot map null,
      quarantined_until null, consecutive_failures,
      firewall_ok bool, virtualized bool, hypervisor_vendor null,
      last_repo_ran_at map, online_at, offline_at, revoked_at,
      update fields …)                                -- Foreman keeps agent keys on boxes too
operations(...)                                       -- copy Foreman; args never include jit_config
vms(id, box_id, name unique, repo_id, class_key [string], size_id, vcpus, memory_mib,
    disk_gib, image_id, lease_index, start_op_id null,
    state enum(requested, starting, booted, idle, busy, finished, failed, destroyed),
    fail_reason null, job_id null, runner_id null, deadline, log_epoch null,
    last_log_seq, last_log_n,
    requested_at, started_at, booted_at, idle_at, busy_at, finished_at, failed_at,
    destroyed_at)
vm_events(id, vm_id, kind, payload map, at)
class_state(repo_id, class_key [string], consecutive_failures, backoff_until null,
            stalled_until null, idle_max_reaps, pk(repo_id, class_key))

images(id, version, arch, manifest bytes, signature, kernel_sha256, rootfs_sha256,
       runner_version, registered_at, pinned bool)
box_images(box_id, image_id, state, progress, error, retry_at null, updated_at)

log_segments(source enum(vm, job), owner_id, first_n, last_n, byte_offset, byte_len,
             pk(source, owner_id, first_n))

box_metrics(box_id, t, cpu_pct, mem_used_mib, mem_total_mib, swap_used_mib, load1,
            disk_used_mib, disk_total_mib, vm_area_free_mib, cache_used_mib, vms_running)
vm_metrics(vm_id, box_id, job_id null, t, cpu_pct, mem_used_mib, mem_total_mib,
           disk_used_mib, net_rx_bps, net_tx_bps, host_cpu_pct, host_rss_mib)
cache_stats(box_id, t, host, hits, misses, bytes_served, bytes_stored, mismatches)

webhook_deliveries(github_delivery_id unique, event, action, received_at,
                   processed_at null, error null)              -- no payload column
cache_config(singleton: enabled_hosts [string], allowlist [string], parent_enabled bool)
cache_tokens(id, box_id, kind enum(parent, mgmt), token_hash, expires_at)
```

**Indexes** (beyond the uniques):
- `jobs(classification, gh_state, queued_at)`
- `jobs(repo_id, completed_at desc)`
- `jobs(run_attempt_id)`
- `vms(box_id, state)`
- `vms(repo_id, class_key, state)`
- `vm_metrics(vm_id, t)`
- `box_metrics(box_id, t)`
- `job_events(job_id, at)`

## 23. Testing

- **`crew_protocol`:**
  - contract tests for every command, event and guest API body;
  - StreamData fuzzing of invalid inputs;
  - table tests for `Labels.parse/3` (case, generic labels, aliases, every
    unsatisfiable reason).
- **Scheduler** (`Plan.plan/1` is pure), with property tests that:
  - memory, including VMM overhead, is never overcommitted;
  - every placement fits;
  - demand is met once capacity frees;
  - two repos alternate;
  - excess is reaped;
  - stalled classes back off;
  - offline boxes' VMs leave supply;
  - VM names are unique.
  - **Fixed tests:** the worked example (§8.3) and the full §8.6 transition
    table, every cell.
- **GitHub:**
  - the client against recorded fixtures (`Req.Test`);
  - webhook signatures with GitHub's test vectors;
  - out-of-order and duplicate deliveries converge;
  - concurrent workers can't move a job backwards (on Postgres and SQLite);
  - the write bucket and budget classes.
- **Control plane:** Foreman's fake agent over the channel, and the null
  driver for end-to-end UI tests.
- **Agent:**
  - drivers behind the behaviour, with Mox;
  - `crew-vmctl` verb validation (Go unit tests, including path traversal
    and out-of-range values);
  - the conformance suite (§11.6).
- **crew_cache,** against a local `distribution` registry and recorded
  upstreams:
  - the allowlist and pass-through matrix;
  - anonymous-fetch fallback;
  - digest mismatch;
  - fetch coalescing;
  - eviction;
  - Host/SNI;
  - redirects to blocked addresses;
  - after every test, an assertion that nothing credentialed was stored;
  - the name constraints, checked with Go, OpenSSL, Node and the JDK.
- **Log viewer** (Playwright, `e2e/`), with a 500k-line fixture:
  - no frame over 50 ms;
  - search;
  - ReDoS timeouts;
  - follow mode;
  - groups;
  - ANSI;
  - XSS fixtures that render as text.
- **End to end** (`e2e/github/`, a test App and test repo with their own
  deployment id), before each release:
  - 30 jobs over 3 sizes on 2 boxes;
  - a cancellation mid-queue;
  - a re-run;
  - a fork-PR refusal, both by the scheduler and by the hook (forced
    cross-class);
  - an agent update mid-job (the job must finish);
  - a control plane restart mid-placement;
  - **Reboot** on a box with a busy job: no new placements, the job
    finishes, the box reboots and rejoins, and the drain clears; then
    **Reboot now** fails its running job and reboots at once;
  - with `E2E_OS_UPDATE=1`, a real Flatcar update (copy Foreman's
    `e2e/flatcar/run.sh`): first-boot version, then a newer one flagged,
    rebooted from the page, and the flag cleared.
- **Crew's own CI** runs on GitHub-hosted runners, never on Crew.

## 24. Spikes

Run these first. They decide details, not the architecture.

| # | Question | How | If it fails |
|---|---|---|---|
| S1 | Does Firecracker (arm64) run, with Docker inside, in a Flatcar VM under VZ nested virtualization on the M3 Max? Third parties report a working `/dev/kvm` in such guests; nobody documents Firecracker there. Does the guest kernel need arguments to bring KVM up at virtual EL2? | `mac-vm.sh` (vfkit `--nested`), Flatcar arm64 (its kernel has `CONFIG_KVM=y`), `/dev/kvm`, a microVM running `docker run hello-world`. Measure boot time and a CPU-bound benchmark against the same job under native vz. | The M3 becomes a `mac-vz` box like the M1. Nothing else changes. |
| S2 | **Resolved** by ntodd/foreman#132: Flatcar arm64 boots under vfkit's EFI bootloader on an M4 Max, and the prep boot of §12.3 stages the Ignition. Its e2e run covers enrollment, reboots, a killed VM, sleep and a real Flatcar update. | What's left is folded into S1 (nested, on the M3) and S3 (as a LaunchDaemon) | None needed |
| S3 | Under launchd, with nobody logged in, after a reboot: does VZ work from a LaunchDaemon as `_crewvm`? Does the `sandbox-exec` profile work? Can the helper reach the cache VM (local network privacy)? Does vfkit, with NAT networking, work from a LaunchDaemon (Foreman's runs as a LaunchAgent), and as `_crewvm`? | Install, reboot, test | LaunchAgents can't be the fallback (local network privacy, and nobody is logged in). Run vfkit as root and document it. For `mac-vz`, run unsandboxed as `_crewvm`, documented in security.md. |
| S4 | Is the `crew-vz` netstack isolated and fast enough? | Conformance 5 plus `iperf3` and `docker pull` (≥ 1 Gbit/s) | First, `VZVmnetNetworkDeviceAttachment` with one vmnet network per VM (macOS 26+), if conformance 5 passes (Apple doesn't document isolation between networks). Second, VZ NAT plus a pf ruleset (needs root). |
| S5 | Do page capture and worker-log parsing work at the pinned runner version (naming, timestamps, read-after-delete, step records)? **Are pages masked?** | A job with a secret, `::add-mask::`, nested groups and a 20 MB step | Unmasked pages: no live log (§16.2). Worker log won't parse: steps from the API while watched, and page order otherwise. |
| S6 | Does a JIT runner get exactly the labels passed, and nothing else? How long does an unused one stay registered? | Register `[crew-m]`; check it in the API; run `runs-on: [self-hosted, crew-m]` against it (must not match); leave one unused for 25 h | Defaults added: include them in every class key on both sides. Lingering runners are handled by Crew's GC. |
| S7 | crew-guest's boot cost | Kernel start to `GET /v1/payload` | Rewrite its boot path as a small static binary (Later). It doesn't block v1. |
| S8 | Mirrors (Design A) or interception (Design B)? Does dockerd with the containerd image store honour `hosts.toml`, in `/etc/docker/certs.d` or `/etc/containerd/certs.d`, for non-Docker-Hub registries, through a mirror at `10.199.0.1`? | Docker (pinned) in the guest; public and private pulls from every host in §15.3 | Design B |
| S9 | How stale can a runner be before GitHub stops assigning it jobs? Does a decoded JIT config's `.runner` carry `DisableUpdate: true`? | GitHub docs and changelog; decode a JIT config; try an old runner | Adjust the freshness thresholds. If JIT runners don't disable updates, find the supported switch, or block the runner's update endpoint inside the guest image. |
| S10 | Do GitHub-hosted Ubuntu runners have `/dev/kvm`? Does the jailer `exec` Firecracker so the unit's main PID is the VMM? Does `--no-api` work for the whole lifecycle we need? | A workflow running Firecracker under the §11.3 unit | Conformance runs on a Crew box. If the PID isn't the VMM, add `-p PIDFile=` with the jailer's pid file. If `--no-api` is too limiting, keep the API socket inside the jail, owned by the VM's uid. |
| S11 | Boot latency end to end on each box type | 20 concurrent starts | p95 over 10 s: look at snapshot restore (Later) |
| S12 | How does a box learn the site's public egress IP for `site4`? | Compare the Tailscale endpoint the control plane sees with `curl` from the box to a fixed echo service | The agent asks a fixed echo service (configurable) at boot and every 10 minutes |

## 25. Build order

Each step ends with something that runs.

1. **Spikes that need no product code:** S3 (with throwaway helpers),
   S5, S6, S8, S9, S10. Write the results into `docs/architecture.md`
   "Spike results", as in Foreman.
2. **The repo skeleton:**
   - the Mix projects and `native/`;
   - CI: format, warnings as errors, credo, sobelow, tests, govulncheck;
   - `crew_protocol` with labels, commands, events and guest bodies.
3. **Control plane basics:** copy Foreman's accounts, sign-in, setup,
   layouts, components and CSS, plus Crew's manifest. **Done when:** you can
   sign in on a fresh deployment, and the App is created with webhooks.
4. **GitHub intake:** the webhook endpoint, deliveries and redelivery,
   upserts, classification, run attempts, the reconciler, and repo sync.
   **Done when:** real runs show on the Runs page, with Crew jobs queued and
   the rest `not_ours`.
5. **The agent and the null driver:**
   - connection, enrolment, ops, `vm.start` and `vm.stop`;
   - the guest API, crew-guest against a stub runner;
   - logs with epochs.

   **Done when:** a fake VM lifecycle is visible in the UI.
6. **Scheduler:** the plan, the VM state machine, reaping, stalls,
   quarantine, the property tests. **Done when:** the worked example and the
   transition table pass, simulated on the null driver.
7. **Guest image:** the kernel, the pinned packages, crew-guest, the runner,
   the job-started hook. **Done when:** a real job runs in a Firecracker VM
   on a `linux-metal` box with a JIT runner.
8. **The Firecracker driver, complete:** `crew-vmctl`, the jailer unit,
   nftables, leases, rate limits, adoption, the disk watchdog. **Done
   when:** conformance passes on `linux-metal`.
9. **crew_cache:** per S8 (Design A or B), with DNS, the store, the CA chain
   and management. **Done when:** conformance item 4 passes.
10. **Live logs and telemetry:** capture per S5, storage, the final log,
    the log viewer, VM metrics, timings, the job page.
11. **The UI, complete:** dashboard, runs, stack view, queue, repos, boxes,
    admin pages, masking.
12. **Host VMs:** Ignition, reprovisioning, the `linux-vm` docs,
    the two launchers, the cache and service VMs, then S1 and S12. **Done
    when:** the M3 box passes conformance (or becomes `mac-vz` per S1).
13. **The vz driver:** `crew-vzd`, `crew-vz`, the netstack, the sandbox, the
    macOS install, S4. **Done when:** the M1 passes conformance.
14. **Releases and updates:**
    - signing in a protected environment;
    - the release workflow;
    - agent and cache self-update on Linux and macOS;
    - `crew-update`;
    - image rollout;
    - S7 and S11 measured.
15. **Hardening:** `docs/security.md`, the red-team list (§19.6) worked
    through, the end-to-end suite (§23).
16. **Migration:**
    - aliases for existing labels;
    - move streamhop, clerkcast, capsend, zbtv, zbtv-live, next and foreman
      over one at a time;
    - deregister and stop `~/docker-runners`.

## 26. Decisions

| Topic | Decision |
|---|---|
| Languages | Elixir everywhere. Go only in `native/` (Apple framework helpers and the Linux root helper), with vendored modules. |
| Layout | A monorepo of separate Mix projects |
| Registration | Repo-level JIT runners (v1) |
| Scheduling unit | Class = (repo, label key). Supply tracks demand, and excess is reaped. |
| Job state | Classification and GitHub state are separate fields. Capacity problems block a job; they never make it unsatisfiable. |
| Webhooks | Tailscale Funnel on :8443 to a one-route endpoint; redelivery plus a reconciler |
| Sizes | Admin-defined named sizes; labels `crew[-size][-arch]` |
| Overcommit | Memory never (VMM overhead counted); CPU 1.5× per box |
| VM lifetime | VMs survive agent restarts (systemd units through `crew-vmctl`; `crew-vzd` on macOS) |
| Agent privilege | Unprivileged agent; a root helper with fixed verbs (Linux) |
| Guest network | A /30 per VM. nftables with static interface matching and pre-conntrack anti-spoofing (fc); a per-VM userspace stack (vz). IPv4 only. |
| Registry cache | Per-box pull-through for allowlisted public images. Upstreams compiled in; tags always resolved upstream. Mirrors (A) or interception (B) per S8. |
| Live logs | Captured in the guest from runner pages, stored per VM; GitHub's log is authoritative once fetched |
| Fork PRs | Refused by default, enforced by the runner's job-started hook in the VM |
| Host OS | Flatcar stable, which applies its own signed updates; reboots only by an admin, as drain then reboot (Foreman's model); state on the data disk |
| Clones | Reflink (XFS) / clonefile (APFS); never a full copy |
| Auth | Foreman's, plus GitHub repo-access scoping for members |
| Box trust | Capabilities pinned at enrolment; changes need an admin's approval |

## 27. Later

- **Org-level runners** for org installations: a Crew runner group, and
  classes per `(org, label key)`, so one idle VM serves any repo. It only
  needs the org's "Self-hosted runners" permission.
- **Snapshot restore** for sub-second boots: VMGenID, reseeding after
  restore, and never restoring the same snapshot twice without reseeding.
- **Sticky cache disks** per (repo, arch), promoted only from
  default-branch jobs.
- **A local `actions/cache` server.**
- **Per-repo egress policies** by hostname.
- **macOS guests** on vz (Apple allows 2 per Mac).
- **More drivers:** Cloud Hypervisor (GPU passthrough, virtio-fs), QEMU
  microvm.
- **A warm pool** of pre-booted idle VMs per popular class.
- **crew-guest's boot path as a static binary,** if S7 says so.

---

## Appendix A: review log

Revision 1 was reviewed independently for (a) correctness and completeness
and (b) security and platform realism. Every finding was accepted. The main
changes, by area:

| Area | Change |
|---|---|
| Fork PRs | Enforced in the VM by the runner's job-started hook. The control-plane check now fails closed: run lookups are essential, and unknown runs are blocked. A refused job taken by a Crew runner is killed. |
| Scheduler | Separate classification and GitHub state; capacity problems block instead of making jobs unsatisfiable; offline boxes leave supply; excess reaping; stalled classes; usable-image rules; disk projected per placement; VMM overhead counted; per-VM maxima; fairness recomputed per placement; the plan is pure and JIT generation moved out of the scheduler; a corrected and derivable worked example. |
| VM lifecycle | A full transition table; timeouts delete the runner first; failed-but-alive VMs handled; recovery on control plane boot; `vm.start` never resent and idempotent by id; collision-free runner names scoped to the deployment. |
| GitHub | Crew's own manifest (webhooks on, Administration: write); a write-rate bucket; budget classes; a budgeted reconciler that fetches per run; the job-log format; run attempts as separate rows; conditional upserts; Funnel-aware client IPs; signed webhooks never rate-limited. |
| Agent | An unprivileged agent with the `crew-vmctl` root helper; all state on the data disk; guest sessions persisted; log epochs, acks and resends; `crew-vzd` instead of `launchctl submit`; macOS local network privacy; a sandboxed `_crewvm` helper. |
| Firecracker | A working jailer + systemd-run unit (no jailer cgroups); unique uids by lease; clone ownership; regular files for logs and metrics; console caps; graceful stop through the guest API, since `SendCtrlAltDel` is x86-only. |
| Network | Static `crewt*` rules that fail closed; pre-conntrack anti-spoofing; conntrack caps on input and forward; `site4` against hairpin access; IPv6 and RA hardening; networkd kept off the taps; firewall verification gates placement. |
| Cache | Upstreams compiled in, with no runtime overrides; tags never resolved through the parent; `/v2/` passed through; an anonymous token flow; anonymous-failure fallback; an `Accept`-aware tag cache; an intermediate CA with exclusions and the root key destroyed; mirrors preferred if S8 allows; other trust stores configured; a separate cache VM on the M1; a hardened DNS resolver. |
| Supply chain | Snapshot-pinned packages and a lock file; Flatcar and kernel signatures checked; Go modules vendored and checked with govulncheck; the signing key in a protected environment; first install from GitHub release assets, checked against the published fingerprint; a documented review gate per bump. |
| Guest | systemd packages; a kernel config checked by `check-config.sh` and a Crew list; IPv6 loopback kept; the `DisableUpdate` check; extra trust-store variables; buffering when the guest API is unreachable. |
| Flatcar | `srv-crew.mount`; identity and agent on the data disk; reprovision Ignition; Tailscale on boxes; `wss://` only; Docker masked on boxes; a valid userns sysctl. |
| Host VMs (revision 3) | After ntodd/foreman#132: `crew-hostvm` dropped for pinned vfkit; the Ignition staged by a prep boot, since vfkit's `--ignition` needs vsock in the initrd and macOS can't write the btrfs OEM partition; `linux-vm` gets a launcher copied from Foreman's sandboxed QEMU service; the Ignition fetched by token; the OEM copy of the Ignition deleted after enrollment; the RTC clock sync on VZ; `/etc` noexec and console handling; sparse disks on APFS; LaunchDaemons where Foreman uses a LaunchAgent; a sleep warning. S2 closed. OS updates switched to Foreman's model: Flatcar updates itself, `box.reboot` reports it, and an admin's **Reboot** drains and then reboots through `box.restart` and `crew-vmctl reboot`; the service VM and cache VM get their own reboot paths. |
| UI | Masking for members everywhere; PubSub carrying ids only; access re-checked per event; ReDoS limits; byte caps; safe raw downloads; annotation links built, never auto-linked; empty states. |
