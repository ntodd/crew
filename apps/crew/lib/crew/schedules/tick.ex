defmodule Crew.Schedules.Tick do
  @moduledoc """
  Fires the schedules that are due (§7.6). Oban runs it every minute. A
  slow tick can overlap the next one; that's safe, because
  `Crew.Schedules.fire/2` claims a schedule's minute before dispatching,
  so the second tick finds nothing to fire. A minute with no tick at all
  is caught up by the next, since `Crew.Schedules.due/1` compares each
  cron against the schedule's clock rather than the current minute. One
  schedule's crash is logged and the rest still fire.
  """
  use Oban.Worker, queue: :github, max_attempts: 1, unique: [period: 50]

  require Logger

  alias Crew.Schedules

  @impl true
  def perform(_job) do
    if Crew.GitHub.configured?() do
      now = DateTime.utc_now()
      Enum.each(Schedules.due(now), &fire(&1, now))
    end

    :ok
  end

  defp fire(schedule, now) do
    Schedules.fire(schedule, now)
  rescue
    exception ->
      Logger.error(
        "schedule #{schedule.id}: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )
  catch
    :exit, reason -> Logger.error("schedule #{schedule.id}: exited: #{inspect(reason)}")
  end
end
