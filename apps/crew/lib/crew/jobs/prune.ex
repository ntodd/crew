defmodule Crew.Jobs.Prune do
  @moduledoc """
  Job retention (§9.4), hourly: run attempts, jobs and VM rows older
  than `CREW_JOB_RETENTION_DAYS` go, and their events with them.

  - A job's age is when it completed, or for one that never did, its
    last event. A run attempt goes with its jobs, once every one of them
    is past the retention and the attempt hasn't changed for it either.
    So a run never shows only some of its jobs, and while one of them is
    open the reconciler, which upserts every job it lists for an
    attempt, has none to add back. A job with no run attempt goes on its
    own.
  - A VM's age is when it was destroyed. One that isn't destroyed stays,
    and so does one a job that's kept ran on.

  Nothing goes that the usage rollup may still read (§16.6): the cutoff
  is never later than `Crew.Usage.rows_needed_from/1`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 1800]

  import Ecto.Query

  alias Crew.{Repo, Usage}
  alias Crew.Jobs.{Job, RunAttempt}
  alias Crew.VMs.VM

  @impl true
  def perform(_job) do
    days = Application.get_env(:crew, :job_retention_days, 90)
    now = DateTime.utc_now()

    needed =
      now |> DateTime.to_date() |> Usage.rows_needed_from() |> DateTime.new!(~T[00:00:00.000000])

    cutoff = Enum.min([DateTime.add(now, -days * 86_400), needed], DateTime)

    prune_attempts(cutoff)
    delete_batched(from(j in Job, where: is_nil(j.run_attempt_id), where: ^old(cutoff)))

    delete_batched(
      from(v in VM,
        as: :vm,
        where:
          v.state == "destroyed" and v.destroyed_at < ^cutoff and
            not exists(from j in Job, where: j.vm_id == parent_as(:vm).id)
      )
    )

    :ok
  end

  # A job past the retention: completed before the cutoff, or never and
  # with no event since it.
  defp old(cutoff) do
    dynamic(
      [j],
      coalesce(j.completed_at, coalesce(j.last_event_at, j.seen_at)) <
        type(^cutoff, :utc_datetime_usec)
    )
  end

  # Run attempts with nothing to keep, and their jobs, a batch to a
  # transaction. On SQLite that holds the write lock from the read, so no
  # webhook can give an attempt a young job halfway through. On Postgres
  # one can, so each delete checks again: that job stays, with its
  # attempt.
  defp prune_attempts(cutoff) do
    batch = batch()

    {:ok, n} =
      Repo.transact(fn ->
        ids =
          Repo.all(
            from a in RunAttempt,
              as: :attempt,
              where:
                a.updated_at < ^cutoff and
                  not exists(
                    from j in Job,
                      where: j.run_attempt_id == parent_as(:attempt).id,
                      where: ^dynamic([j], not (^old(cutoff)))
                  ),
              select: a.id,
              limit: ^batch
          )

        # ecto_sqlite3 can't take an empty list for `in`.
        if ids == [] do
          {:ok, 0}
        else
          Repo.delete_all(from j in Job, where: j.run_attempt_id in ^ids, where: ^old(cutoff))

          {n, _} =
            Repo.delete_all(
              from a in RunAttempt,
                as: :attempt,
                where:
                  a.id in ^ids and
                    not exists(from j in Job, where: j.run_attempt_id == parent_as(:attempt).id)
            )

          {:ok, n}
        end
      end)

    if n == batch, do: prune_attempts(cutoff)
  end

  # A batch at a time, so a backlog (the retention lowered, say) doesn't
  # hold SQLite's write lock for long, and checked again as it's deleted.
  # Events and samples go with their rows, on the foreign keys' ON DELETE
  # CASCADE.
  defp delete_batched(query) do
    batch = batch()

    with [_ | _] = ids <- Repo.all(query |> select([r], r.id) |> limit(^batch)),
         {^batch, _} <- Repo.delete_all(where(query, [r], r.id in ^ids)),
         do: delete_batched(query)
  end

  defp batch, do: Application.get_env(:crew, :job_prune_batch, 100)
end
