defmodule Crew.Usage.RerollUnrunJobsMigrationTest do
  # 0.1.7 rolled up the queue time of jobs cancelled before a runner took
  # them as job minutes. The migration forgets the stored days that have
  # one, while their box samples are still kept, so the next rollup
  # computes them again.
  use Crew.DataCase

  alias Crew.Usage
  alias Crew.Usage.{Day, RolledDay}

  @migration Path.expand(
               "../../../priv/repo/migrations/20261109010000_reroll_usage_unrun_jobs.exs",
               __DIR__
             )

  setup_all do
    [{module, _}] = Code.require_file(@migration)
    %{migration: module}
  end

  setup do
    %{repo: repo_fixture(), today: Date.utc_today()}
  end

  defp at(day, s),
    do:
      day
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(s)
      |> Map.put(:microsecond, {0, 6})

  defp unrun_job(repo, day),
    do:
      job_row_fixture(repo,
        runner_name: nil,
        conclusion: "cancelled",
        started_at: at(day, 0),
        completed_at: at(day, 3600)
      )

  defp ran_job(repo, day),
    do: job_row_fixture(repo, started_at: at(day, 0), completed_at: at(day, 60))

  # A version after every real one, so Ecto doesn't warn it's out of order.
  defp migrate(module), do: Ecto.Migrator.up(Repo, 99_999_999_999_999, module, log: false)

  defp rolled, do: Repo.all(from r in RolledDay, order_by: r.day, select: r.day)

  test "forgets stored days with a job no runner took, back 6 days", %{
    migration: migration,
    repo: repo,
    today: today
  } do
    [unrun, ran, old] = [Date.add(today, -3), Date.add(today, -4), Date.add(today, -7)]

    unrun_job(repo, unrun)
    ran_job(repo, unrun)
    ran_job(repo, ran)
    unrun_job(repo, old)

    Repo.insert_all(
      RolledDay,
      for(d <- [unrun, ran, old], do: %{day: d, computed_at: DateTime.utc_now()})
    )

    assert migrate(migration) == :ok
    assert rolled() == [old, ran]

    # The next rollup fills it in without the job no runner took.
    Usage.roll_up(today)
    assert unrun in rolled()
    assert [%{job_count: 1, job_s: 60}] = Repo.all(from d in Day, where: d.day == ^unrun)
  end

  test "does nothing without such jobs", %{migration: migration, repo: repo, today: today} do
    day = Date.add(today, -3)
    ran_job(repo, day)
    Repo.insert_all(RolledDay, [%{day: day, computed_at: DateTime.utc_now()}])

    assert migrate(migration) == :ok
    assert rolled() == [day]
  end
end
