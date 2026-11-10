defmodule Crew.Sizing.CriticalPath do
  @moduledoc """
  A run attempt's critical path (§7.5): its longest chain of dependent
  jobs, which sets how long the run takes. GitHub's jobs don't say what
  they `needs:`, so the chain is inferred from their times. GitHub
  queues a job with `needs:` (its `created_at`, Crew's `queued_at`) as
  the last of them finishes, so the path runs back from the job that
  finished last, through the jobs that finished as each one was queued,
  to the jobs queued at the run's start.

  Jobs that finish within a tolerance of the path (5% of the run, at
  least 2 s) are on it too: matrix legs that finish together share a
  size, and speeding up the one that happened to finish last wouldn't
  finish the run sooner alone. Pure; `Crew.Sizing` reads the jobs.
  """

  @min_tolerance_us 2_000_000
  @tolerance 0.05

  @doc """
  The ids of the jobs on the critical path of one run attempt's jobs
  (maps with `id`, `queued_at`, `started_at` and `completed_at`). Nil
  without jobs, while one hasn't finished, or when the path can't be
  followed back to the run's start: a job queued when nothing had just
  finished, which GitHub doesn't do, so a job Crew missed.
  """
  @spec ids([map()]) :: MapSet.t() | nil
  def ids([]), do: nil

  def ids(jobs) do
    if Enum.all?(jobs, &(ready_at(&1) && &1.completed_at)) do
      start = jobs |> Enum.map(&ready/1) |> Enum.min()
      finish = jobs |> Enum.map(&done/1) |> Enum.max()
      tolerance = max(@min_tolerance_us, round((finish - start) * @tolerance))
      ends = Enum.filter(jobs, &(done(&1) >= finish - tolerance))

      back(ends, jobs, MapSet.new(ends, & &1.id), {start, tolerance})
    end
  end

  # Walks back from each job on the path to the jobs that finished as it
  # was queued (never after), or stops at one queued at the run's start.
  defp back([], _jobs, path, _run), do: path

  defp back([job | rest], jobs, path, {start, tolerance} = run) do
    at = ready(job)
    before = Enum.filter(jobs, &(done(&1) <= at and done(&1) >= at - tolerance))
    prev = Enum.reject(before, &MapSet.member?(path, &1.id))

    if before == [] and at - start > tolerance,
      do: nil,
      else: back(prev ++ rest, jobs, Enum.reduce(prev, path, &MapSet.put(&2, &1.id)), run)
  end

  defp ready_at(job), do: job.queued_at || job.started_at
  defp ready(job), do: DateTime.to_unix(ready_at(job), :microsecond)
  defp done(job), do: DateTime.to_unix(job.completed_at, :microsecond)
end
