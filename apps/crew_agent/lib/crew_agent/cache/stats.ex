defmodule CrewAgent.Cache.Stats do
  @moduledoc """
  Every 60 s, the box cache's counters as `cache.stats` (§10.4): what
  changed since the last report, so the control plane's rows sum. A
  counter that went down means the cache restarted, and counts from 0.
  """
  use GenServer

  alias CrewAgent.{Cache, Config, Outbox}

  @every_ms 60_000
  @counters ~w(hits misses bytes_served bytes_stored)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.send_after(self(), :report, @every_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:report, previous) do
    Process.send_after(self(), :report, @every_ms)

    case Cache.stats(Config.get()) do
      {:ok, current} ->
        {report, current} = delta(previous, current)

        {:ok, event} =
          CrewProtocol.Event.new("cache.stats", Map.put(report, :t, System.os_time(:millisecond)))

        Outbox.push(event)
        {:noreply, current}

      _ ->
        {:noreply, previous}
    end
  end

  @doc "The report between two `GET /stats` answers, and the one to compare the next against."
  def delta(previous, current) do
    previous = previous || %{}
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

  defp host_delta(h, was),
    do:
      Map.new([
        {:host, h["host"]} | for(k <- @counters, do: {String.to_atom(k), diff(h[k], was[k])})
      ])

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
