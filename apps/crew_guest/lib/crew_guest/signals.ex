defmodule CrewGuest.Signals do
  @moduledoc """
  What SIGTERM does to crew-guest (§13.5).

  A graceful stop of the VM (the power button, ctrl-alt-del) reaches
  crew-guest as systemd's SIGTERM, with the unit's stop timeout before
  SIGKILL. The BEAM's own handler (`erl_signal_handler`) answers SIGTERM
  with `init:stop/0`, which stops the release without stopping the runner
  or flushing what's held, and waits out each process's shutdown timeout
  on the way.

  `install/1` puts this handler in its place on `erl_signal_server`.
  SIGTERM calls `:on_sigterm` (`CrewGuest.Session.sigterm/0` in the
  release), which starts the ordered stop and returns at once: the handler
  runs in the signal server, so it mustn't block. It also arms a backstop:
  if the BEAM is still up `:deadline_ms` after the first SIGTERM, it
  halts (status 1), well before systemd's SIGKILL would. SIGUSR1 and
  SIGQUIT keep the BEAM's handling.
  """

  @behaviour :gen_event

  require Logger

  @manager :erl_signal_server
  @default :erl_signal_handler

  @doc """
  Takes SIGTERM over from the BEAM's handler. Installing again replaces
  the earlier install. Options:
  - `:on_sigterm` (required), a function of no arguments;
  - `:deadline_ms` (default 8 000), when the backstop halts;
  - `:on_deadline`, what the backstop does (for tests).
  """
  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts) do
    args = Map.new(opts)

    # A swap is atomic: no SIGTERM finds the server without a handler.
    if __MODULE__ in :gen_event.which_handlers(@manager),
      do: :gen_event.swap_handler(@manager, {__MODULE__, :reinstall}, {__MODULE__, args}),
      else: :gen_event.swap_handler(@manager, {@default, []}, {__MODULE__, args})
  end

  @doc "Gives SIGTERM back to the BEAM's handler."
  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    if __MODULE__ in :gen_event.which_handlers(@manager),
      do: :gen_event.swap_handler(@manager, {__MODULE__, :uninstall}, {@default, []}),
      else: :ok
  end

  # Handler

  @impl true
  # Swapped in, the args come with the old handler's terminate result.
  def init({%{} = args, _swapped}), do: init(args)

  def init(%{} = args) do
    {:ok,
     %{
       on_sigterm: Map.fetch!(args, :on_sigterm),
       deadline_ms: Map.get(args, :deadline_ms, 8_000),
       on_deadline: Map.get(args, :on_deadline, &halt/0),
       armed: false
     }}
  end

  @impl true
  def handle_event(:sigterm, s) do
    Logger.info("crew-guest: SIGTERM; stopping")
    s = arm(s)
    s.on_sigterm.()
    {:ok, s}
  end

  def handle_event(signal, s) do
    {:ok, _} = @default.handle_event(signal, s)
    {:ok, s}
  end

  @impl true
  def handle_info({__MODULE__, :deadline}, s) do
    s.on_deadline.()
    {:ok, s}
  end

  def handle_info(_msg, s), do: {:ok, s}

  @impl true
  def handle_call(_request, s), do: {:ok, :ok, s}

  defp arm(%{armed: true} = s), do: s

  defp arm(s) do
    Process.send_after(self(), {__MODULE__, :deadline}, s.deadline_ms)
    %{s | armed: true}
  end

  defp halt do
    Logger.error("crew-guest: still running after SIGTERM's deadline; halting")
    # Flushing output (the log line above) gets half a second at most.
    :erlang.halt(1, flush_timeout: 500)
  end
end
