defmodule Crew.Repo.Migrations.RerollUsageUnrunJobs do
  use Ecto.Migration
  import Ecto.Query

  # 0.1.7's usage rollup counted jobs cancelled in the queue: GitHub
  # stamps them with a started_at but no runner, so their wait counted as
  # job minutes (§16.6). This forgets the stored days that have one, and
  # the next hourly rollup computes them again without it.
  #
  # Only days whose box samples are all still kept (7 days, §9.4): a day
  # rolled up again without them would lose its online time. Older days
  # keep what was stored.
  def up, do: forget(repo())

  # Public so its test can run it on the sandbox, which the migrator's
  # lock can't share on Postgres.
  def forget(repo) do
    since = Date.utc_today() |> Date.add(-6) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    days =
      repo.all(
        from(j in "jobs",
          where:
            j.classification == "ours" and j.gh_state == "completed" and
              not is_nil(j.started_at) and (is_nil(j.runner_name) or j.runner_name == "") and
              j.completed_at >= type(^since, :utc_datetime_usec),
          select: type(j.completed_at, :utc_datetime_usec)
        )
      )
      |> Enum.map(&DateTime.to_date/1)
      |> Enum.uniq()

    # A day at a time: ecto_sqlite3 takes neither an empty list nor a
    # typed one for `in`, and there are at most 7.
    for day <- days,
        do: repo.delete_all(from(r in "usage_rollups", where: r.day == type(^day, :date)))

    :ok
  end

  def down, do: :ok
end
