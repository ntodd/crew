defmodule CrewAgent.Cache.Stats do
  @moduledoc """
  Keeps the box cache in step with the agent, every 60 s:

  - **`cache.stats`** (§10.4): what changed since the last report, so the
    control plane's rows sum. The baseline is kept in
    `agent/cache-stats.json`, so an agent restart doesn't report the
    cache's lifetime again; a cache that restarted (a new `instance`, or
    counters that went down) counts from 0.
  - **site4** (§15.5): the box's networks and egress address, which the
    cache refuses to connect to, pushed whenever they change (the
    egress address is learned after start, and can move) and again
    after a push that failed.
  """
  use GenServer

  require Logger

  alias CrewAgent.{Cache, Config, Outbox, Site}

  @every_ms 60_000
  # Counters run from the cache's start; bytes_stored is a level.
  @counters ~w(hits misses bytes_served)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :site4)
    Process.send_after(self(), :report, @every_ms)
    {:ok, %{previous: :unloaded, site4: nil}}
  end

  @impl true
  def handle_info(:site4, state) do
    Process.send_after(self(), :site4, @every_ms)
    config = Config.get()
    {_, pushed} = sync_site4(config, state.site4, Site.current(config))
    {:noreply, %{state | site4: pushed}}
  end

  def handle_info(:report, state) do
    Process.send_after(self(), :report, @every_ms)
    config = Config.get()

    case Cache.stats(config) do
      {:ok, current} ->
        :persistent_term.put({__MODULE__, :store_bytes}, int(get_in(current, ["store", "bytes"])))

        previous =
          if state.previous == :unloaded, do: baseline(config, current), else: state.previous

        {report, current} = delta(previous, current)

        {:ok, event} =
          CrewProtocol.Event.new("cache.stats", Map.put(report, :t, System.os_time(:millisecond)))

        Outbox.push(event)
        save_baseline(config, current)
        {:noreply, %{state | previous: current}}

      _ ->
        {:noreply, state}
    end
  end

  @doc """
  Pushes `site4` to the cache unless it's what was pushed last.
  `{:ok, pushed}`, or `{:error, last}` to try again next time.
  """
  def sync_site4(_config, last, site4) when last == site4, do: {:ok, last}

  def sync_site4(config, last, site4) do
    case Cache.put_site4(config, site4) do
      :ok ->
        {:ok, site4}

      {:error, reason} ->
        Logger.warning("the cache didn't take the box's site4 (#{inspect(reason)}); retrying")
        {:error, last}
    end
  end

  @doc "The last report's counters, if they're from this cache instance."
  def baseline(config, current) do
    with {:ok, json} <- File.read(baseline_file(config)),
         {:ok, %{} = saved} <- Jason.decode(json),
         true <- same_instance?(saved["instance"], current["instance"]) do
      saved
    else
      _ -> nil
    end
  end

  defp same_instance?(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp same_instance?(_, _), do: true

  def save_baseline(config, stats) do
    path = baseline_file(config)
    File.mkdir_p!(Path.dirname(path))
    CrewAgent.SafeFS.write_atomic(path, Jason.encode!(stats), 0o640)
  end

  defp baseline_file(config), do: Path.join([config.data_dir, "agent", "cache-stats.json"])

  @doc "How much the cache holds, from its last `GET /stats` (0 before one)."
  def store_mib, do: div(:persistent_term.get({__MODULE__, :store_bytes}, 0), 1_048_576)

  @doc "The report between two `GET /stats` answers, and the one to compare the next against."
  def delta(previous, current) do
    # A cache that restarted since the last report counts from 0.
    previous =
      if same_instance?((previous || %{})["instance"], current["instance"]),
        do: previous || %{},
        else: %{}

    before = Map.new(previous["hosts"] || [], &{&1["host"], &1})

    report = %{
      hosts:
        for(
          h <- current["hosts"] || [],
          is_binary(h["host"]),
          do: host_delta(h, before[h["host"]] || %{})
        ),
      top: top(current["top"] || []),
      evictions: diff(current["evictions"], previous["evictions"]),
      digest_mismatches: diff(current["digest_mismatches"], previous["digest_mismatches"])
    }

    {report, current}
  end

  defp host_delta(h, was) do
    counters = for k <- @counters, do: {String.to_atom(k), diff(h[k], was[k])}
    Map.new([{:host, h["host"]}, {:bytes_stored, int(h["bytes_stored"])} | counters])
  end

  defp top(entries) do
    for t <- Enum.take(entries, 10), is_binary(t["host"]) and is_binary(t["repo"]) do
      %{
        host: t["host"],
        repo: t["repo"],
        hits: int(t["hits"]),
        bytes_served: int(t["bytes_served"])
      }
    end
  end

  defp diff(now, was) do
    now = int(now)
    was = int(was)
    if now >= was, do: now - was, else: now
  end

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0
end
