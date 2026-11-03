defmodule CrewGuest.Session do
  @moduledoc """
  One boot of crew-guest: the outbox and the boot sequence, sharing a
  client whose stop signal goes to `CrewGuest.Main`.

  If `Main` crashes it's restarted, and the restart asks for the payload
  again: the agent answers 410, so the VM powers off rather than hanging
  with nobody watching the runner.
  """

  use Supervisor

  require Logger

  alias CrewGuest.{API, Main, Outbox}
  alias CrewGuest.System.Linux

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    cfg = Keyword.fetch!(opts, :config)
    system = Keyword.fetch!(opts, :system)
    client = API.from_config(cfg, on_stop: &Main.request_stop/0)
    version = Application.spec(:crew_guest, :vsn)

    Logger.info("crew-guest #{version}: VM #{cfg.vm_id}, #{cfg.mode} mode, API #{cfg.api_url}")

    children = [
      {Outbox, name: Outbox, client: client},
      {Main, config: cfg, system: system, client: client, outbox: Outbox}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  What to do when there's no usable config: nothing can be reported
  without one, so in a VM, power off (the agent sees `boot_failed`), and
  locally, exit non-zero.
  """
  def fail(reason) do
    Logger.error("crew-guest: can't start: #{inspect(reason)}")

    # Nothing has started that would need a clean stop.
    case System.get_env("CREW_GUEST_MODE") do
      mode when mode in [nil, "", "vm"] -> Linux.poweroff(nil)
      _local_or_unknown -> System.halt(1)
    end
  end
end
