defmodule CrewAgent.Driver.Firecracker.Monitor do
  @moduledoc """
  The Firecracker driver's own timers, on a Firecracker box:

  - **The packet filter** (§14.2): `crew-vmctl nft-verify` at start and
    every 60 s, which holds the loaded ruleset to the shipped one and
    site4 to what crew-net puts in it. With an echo service configured
    (`CREW_EGRESS_ECHO_URL`), site4 must also hold the egress address the
    agent learned. The verdict is `firewall_ok` in the capabilities, and
    no VM starts without it.
  - **The console cap** (§11.3) every second, for each running VM's
    `console.log` in the jail.

  A site4 that's missing something, or holds an old egress address, is
  refilled (`crew-vmctl site4`) and checked once more before it counts
  as a failure.

  It also owns the table of CPU samples `stats/1` takes its deltas from.
  """
  use GenServer

  require Logger

  alias CrewAgent.{Config, Site}
  alias CrewAgent.Driver.Firecracker
  alias CrewAgent.Driver.Firecracker.Console

  @verify_ms 60_000
  @console_ms 1_000
  @stats :crew_fc_stats
  @key {__MODULE__, :status}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the last verdict was good, or nil before the first."
  def firewall_ok? do
    case status() do
      nil -> nil
      s -> ok?(s)
    end
  end

  @doc """
  `:ok` when a VM may start: the last verdict was good (one is taken now
  if there's none yet). Otherwise why not.
  """
  def ready do
    s =
      case status() do
        nil ->
          verify()
          status()

        s ->
          s
      end

    if ok?(s), do: :ok, else: {:error, why(s)}
  end

  @doc "The last verdict: `%{filter: ..., egress: ..., site4_egress: ...}`, or nil."
  def status, do: :persistent_term.get(@key, nil)

  @doc false
  def reset, do: :persistent_term.erase(@key)

  @doc "Verifies the filter and caps the consoles now (tests: `interval: :manual`)."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 60_000)

  @doc "Asks for a verdict soon (site4 just changed)."
  def verify_soon do
    if pid = GenServer.whereis(__MODULE__), do: send(pid, :verify_now)
    :ok
  end

  def stats_table, do: @stats

  defp ok?(%{filter: :ok, egress: egress}), do: egress in [:ok, :not_required]
  defp ok?(_), do: false

  defp why(%{filter: :ok, egress: {:error, why}}), do: why
  defp why(%{filter: {:error, why}}), do: why
  defp why(_), do: "the packet filter hasn't been verified"

  @impl true
  def init(opts) do
    if :ets.whereis(@stats) == :undefined,
      do: :ets.new(@stats, [:set, :public, :named_table, write_concurrency: true])

    unless opts[:interval] == :manual do
      send(self(), :verify)
      Process.send_after(self(), :console, @console_ms)
    end

    {:ok, %{}}
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

  def handle_info(:verify_now, state) do
    verify()
    {:noreply, state}
  end

  def handle_info(:console, state) do
    cap_consoles()
    Process.send_after(self(), :console, @console_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Takes a verdict now and keeps it; true when it's good."
  def verify do
    previous = status()
    {filter, loaded} = check()
    {filter, loaded, egress} = egress(filter, loaded)
    status = %{filter: filter, egress: egress, site4_egress: loaded}
    :persistent_term.put(@key, status)
    log_change(previous, status)
    ok?(status)
  end

  # crew-vmctl's verdict, with one refill and a second look if site4 is
  # what's wrong.
  defp check do
    case nft_verify() do
      {{:error, "site4_not_ready: " <> _}, _} -> refill_and_check()
      other -> other
    end
  end

  defp refill_and_check do
    _ = Firecracker.vmctl(%{"verb" => "site4"})
    nft_verify()
  end

  # {:ok, the egress address site4 holds} or {{:error, why}, nil}.
  defp nft_verify do
    case Firecracker.vmctl(%{"verb" => "nft-verify"}) do
      {:ok, resp} -> {:ok, get_in(resp, ["site4", "egress"])}
      {:error, code, detail} -> {{:error, "#{code}: #{detail}"}, nil}
    end
  end

  # With an echo service, site4 must hold the egress address the agent
  # learned; an old one is refilled and looked at again.
  defp egress(filter, loaded) do
    echo = Application.get_env(:crew_agent, :egress_echo_url)
    agent = Site.egress()

    cond do
      echo in [nil, ""] ->
        {filter, loaded, :not_required}

      is_nil(agent) ->
        {filter, loaded, {:error, "the site's egress address isn't known yet (#{echo})"}}

      filter == :ok and loaded == agent ->
        {filter, loaded, :ok}

      filter == :ok ->
        refill_for(agent)

      true ->
        {filter, loaded, {:error, "site4 couldn't be checked"}}
    end
  end

  defp refill_for(agent) do
    case refill_and_check() do
      {:ok, ^agent} ->
        {:ok, agent, :ok}

      {:ok, other} ->
        {:ok, other, {:error, "site4 holds #{other || "no"} egress address, not #{agent}"}}

      {error, _} ->
        {error, nil, {:error, "site4 couldn't be checked"}}
    end
  end

  defp log_change(previous, status) do
    case {previous && ok?(previous), ok?(status)} do
      {same, same} ->
        :ok

      {_, true} ->
        Logger.info("the packet filter and site4 are verified (crew-vmctl nft-verify)")

      {_, false} ->
        Logger.error("the packet filter isn't verified, so this box takes no VMs: #{why(status)}")
    end
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
