defmodule CrewGuest do
  @moduledoc """
  crew-guest, the init service in each job VM (§13.5).

  It fetches the payload from the agent's guest API (§13.4), sets the VM up
  (DNS, the cache CA, Docker), starts the runner with its JIT config, and
  reports back: states, steps, live log lines and metrics. When the runner
  exits, or the agent asks it to stop, it flushes what it holds and powers
  the VM off. On SIGTERM (systemd stopping the VM) it does the same within
  6 s, then exits.

  The pieces: `CrewGuest.Main` runs the sequence, `CrewGuest.Outbox`
  delivers (and buffers) what's reported, `CrewGuest.Runner` supervises the
  runner, `CrewGuest.Pages` and `CrewGuest.Steps` turn the runner's
  `_diag` files into log lines and steps, `CrewGuest.Signals` handles
  SIGTERM, and every OS step goes through `CrewGuest.System`.

  ## Local mode (the null driver, §11.5)

  The same release runs as a plain process, without root, on Linux or
  macOS. It skips DNS, IPv6, the disk and Docker, runs the runner as the
  current user, and "powers off" by exiting 0 (1 if its settings are
  unusable):

      CREW_GUEST_MODE=local \\
      CREW_GUEST_VM=<vm_id> \\
      CREW_GUEST_TOKEN=<token> \\
      CREW_GUEST_API=http://127.0.0.1:<port> \\
      CREW_GUEST_RUNNER_DIR=<a dir per VM> \\
      CREW_GUEST_RUNNER_CMD=<path to apps/crew_guest/test/fixtures/stub-runner> \\
        _build/<env>/rel/crew_guest/bin/crew_guest start

  The run dir (`policy.json`, `jit`, `guest.env`) defaults to
  `<runner dir>/.crew`; `CREW_GUEST_RUN_DIR` moves it. The payload's
  `jit_config` must still decode to a `.runner` with `DisableUpdate: true`,
  or crew-guest refuses to start the runner. See `CrewGuest.Config`.
  """
end
