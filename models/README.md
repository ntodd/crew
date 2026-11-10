# Models

Formal models of the parts of Crew where three parties race each other
through messages. They're run with [Quint](https://quint-lang.org)'s
random simulator, not model-checked exhaustively: fast, and good at
turning up an interleaving nobody wrote a test for.

```sh
npm i -g @informalsystems/quint
```

## `vm_lifecycle.qnt`

One VM, one job, one box, as seen by the control plane's VM server
(`Crew.VMs.Server` over `Crew.VMs.Machine`), the box's agent
(`CrewAgent.VMs`, `CrewAgent.VM`) and GitHub (the JIT runner and the job).
It's §8.6, §10.6 and §10.7 of `docs/crew_spec.md` with the channels in
between: the agent link is FIFO each way, commands to an offline box are
dropped, the agent's outbox keeps events across a dropped link but not an
agent restart, webhooks come in any order or not at all, and the
reconciler eventually tells the control plane what GitHub has.

`transition` is `Crew.VMs.Machine.transition/2` clause for clause. The
rest of the control plane side is `Crew.VMs.Server`: timers, effects,
`alive_for`, `carry_on`, the restart from the database.

### Invariants

| Name | Claim |
|---|---|
| `destroyedMeansDead` | A destroyed VM has no VMM running (it holds no allocation). |
| `noDoubleBoot` | The agent never boots a `vm_id` twice. |
| `noKillDuringJob` | Only the deadline stops a VM whose runner is on a job. |
| `noRunnerLeak` | A destroyed VM's runner is gone, being deleted, or on a job. |
| `jobLinked` | A job GitHub ran on the VM gets linked to it. |
| `noDeadlock` | A VM that isn't destroyed can still get there without another fault. |

`safe` is all of them but `jobLinked`.

Faults (restarts, dropped links, crashes, lost webhooks, timeouts that
beat a message still in flight) spend from a per-run budget of three, so
random runs get past the first steps. `initCalm` starts with none.

```sh
# Random simulation. --backend=typescript runs the JS evaluator instead of Rust.
quint run models/vm_lifecycle.qnt --invariant=safe --max-samples=100000 --max-steps=100
quint run models/vm_lifecycle.qnt --invariant=noKillDuringJob --max-samples=200000 --max-steps=100

# The witnesses: scripted runs that walk the paths the random ones seldom find.
quint test models/vm_lifecycle.qnt
```

### What it found

Both `noKillDuringJob` violations came from the `requested` state taking
the shortcut that no other pre-job state takes: it failed the VM and
deleted its runner in the background (`Crew.VMs.DeleteRunner`, fire and
forget), where `starting`, `booted` and `idle` delete first and act on the
answer (204 or 404: stop; 422: the runner has a job, go `busy`).

- **`cp_restart`** (#106, `Server.handle_continue(:boot)`): the control plane
  restarts between sending `vm.start` and handling its `op.result`. The
  VM boots, its runner takes the queued job, and the restarted control
  plane fails it, sends `vm.stop force`, and keeps sending one from the
  `check` timer until the box's inventory stops listing it. The in-flight
  Oban delete gets a 422 and is done. `cpRestartKillsJobTest` walks it;
  the random runs find it within a few hundred thousand samples. The
  server is fixed (#112), but the model's `cpRestart` still takes the old
  path, so it still finds this one.
- **`box_disconnected`** in `requested` (#108, `Machine.transition/2`): the same
  through a dropped link, with the stop arriving as `inventory_alive`
  when the box rejoins. Fixed: `requested` now deletes the runner first
  like the other pre-job states, and `disconnectKeepsJobTest` walks the
  422 to `busy`. Without a runner yet (the JIT call still out), the server
  applies the `:gone` answer in the same step rather than sending it to
  itself, or a JIT config already in its mailbox would register a runner
  and send `vm.start` to a VM that then fails.

Both need the runner to take the job before the background delete lands,
so GitHub's delete has to be slow or failing (the Oban job retries every
30 s) while the VM boots. Narrow, but a deploy during a placement is
ordinary. The fix in both is to use `{:delete_runner_then, reason}` from
`requested` as the other states do: the machine already handles the 422
answer.

`jobLinked` holds on random runs, and `finishedLinksJobTest` walks the
path they seldom find (#107): a VM that went `busy` on the guest's
`job_started` hook, then exited with a cleanup error before GitHub's
`in_progress` arrived, sits in `finished` with its server up, so
`late_link/2` never runs. `finished` with no job links the job either
webhook names.

### Replay against the Elixir machine

Every control plane step in a trace records the VM it passed to the
machine, the event, and the answer (`steps`). `export_steps.exs` collects
them from ITF traces into
`apps/crew/test/fixtures/quint/vm_lifecycle_steps.json`, and
`apps/crew/test/crew/vms/machine_replay_test.exs` feeds each one to
`Crew.VMs.Machine.transition/2`. If the Elixir table and the model drift,
that test names the cell.

To regenerate after changing the model:

```sh
mkdir -p /tmp/traces /tmp/calm
quint run models/vm_lifecycle.qnt --invariant=safe --mbt --seed=0x1 \
  --max-samples=3000 --max-steps=80 --n-traces=3000 --out-itf=/tmp/traces/t{seq}.itf.json
quint run models/vm_lifecycle.qnt --init=initCalm --invariant=safe --mbt --seed=0x2 \
  --max-samples=3000 --max-steps=80 --n-traces=3000 --out-itf=/tmp/calm/c{seq}.itf.json
elixir models/export_steps.exs apps/crew/test/fixtures/quint/vm_lifecycle_steps.json \
  /tmp/traces/*.itf.json /tmp/calm/*.itf.json
```

### Not modeled

Two VMs or two jobs (so nothing about placement, allocation or fairness),
box revocation, the delete-runner give-up after `CREW_IDLE_MAX + 300 s`
of GitHub errors, image state, logs, and the agent's lease conflicts.
