defmodule Crew.Reconciler.Ticker do
  @moduledoc """
  Queues `Crew.Reconciler` every 15 s (Oban's cron is per minute, and
  poll-only mode can sweep faster), and `Crew.GitHub.Redeliver` at boot.
  The reconciler's uniqueness keeps one queued at a time.
  """
  use GenServer

  @every :timer.seconds(15)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :boot)
    {:ok, nil}
  end

  @impl true
  def handle_info(:boot, state) do
    Oban.insert(Crew.GitHub.Redeliver.new(%{}))
    send(self(), :tick)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    if Crew.GitHub.configured?(), do: Oban.insert(Crew.Reconciler.new(%{}))
    Process.send_after(self(), :tick, @every)
    {:noreply, state}
  end
end
