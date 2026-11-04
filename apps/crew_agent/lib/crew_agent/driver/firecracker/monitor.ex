defmodule CrewAgent.Driver.Firecracker.Monitor do
  @moduledoc """
  The Firecracker driver's own timers, on a Firecracker box:

  - **`crew-vmctl nft-verify`** at start and every 60 s (§14.2). The
    verdict is `firewall_ok` in the capabilities, which the reporter
    sends again when it changes; a mismatch makes the box ineligible.
  - **The console cap** (§11.3) every second, for each running VM's
    `console.log` in the jail.

  It also owns the table of CPU samples `stats/1` takes its deltas from.
  """
  use GenServer

  require Logger

  alias CrewAgent.Config
  alias CrewAgent.Driver.Firecracker
  alias CrewAgent.Driver.Firecracker.Console

  @verify_ms 60_000
  @console_ms 1_000
  @stats :crew_fc_stats

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The last verdict, or nil before the first."
  def firewall_ok?, do: :persistent_term.get({__MODULE__, :firewall_ok}, nil)

  @doc "Verifies the ruleset and caps the consoles now (tests: `interval: :manual`)."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 60_000)

  def stats_table, do: @stats

  @impl true
  def init(opts) do
    if :ets.whereis(@stats) == :undefined,
      do: :ets.new(@stats, [:set, :public, :named_table, write_concurrency: true])

    unless opts[:interval] == :manual do
      send(self(), :verify)
      Process.send_after(self(), :console, @console_ms)
    end

    {:ok, %{manual: opts[:interval] == :manual}}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    verify()
    cap_consoles()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:verify, state) do
    verify()
    Process.send_after(self(), :verify, @verify_ms)
    {:noreply, state}
  end

  def handle_info(:console, state) do
    cap_consoles()
    Process.send_after(self(), :console, @console_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def verify do
    {ok, detail} =
      case Firecracker.vmctl(%{"verb" => "nft-verify"}) do
        {:ok, _} -> {true, nil}
        {:error, code, detail} -> {false, "#{code}: #{detail}"}
      end

    case {firewall_ok?(), ok} do
      {same, same} ->
        :ok

      {_, true} ->
        Logger.info("the packet filter is verified (crew-vmctl nft-verify)")

      {_, false} ->
        Logger.error("the packet filter doesn't verify, so this box is ineligible: #{detail}")
    end

    :persistent_term.put({__MODULE__, :firewall_ok}, ok)
    ok
  end

  defp cap_consoles do
    config = Config.get()

    for path <-
          Path.wildcard(Path.join([config.data_dir, "jail", "firecracker", "*", "console.log"])),
        CrewProtocol.uuid?(path |> Path.dirname() |> Path.basename()) do
      case Console.cap(path) do
        {:truncated, omitted} -> Logger.debug("capped #{path} (#{omitted} bytes dropped)")
        :ok -> :ok
      end
    end

    :ok
  end
end
