defmodule Crew.Sizing do
  @moduledoc """
  Right-sizing hints (§7.5) for a job, a repo's jobs and the fleet: reads
  each job's latest runs (its summaries, §16.5) and the sizes its repo may
  use, and asks `Crew.Sizing.Rules`.

  Display only. Nothing here changes placement, labels or sizes.
  """
  import Ecto.Query

  alias Crew.{Repo, Repos, Scope, Sizes}
  alias Crew.Jobs.Job
  alias Crew.Sizing.Rules

  # Rows read per job: more than the rules' window, since only the runs
  # on the newest one's shape count.
  @history 30
  # A repo's jobs that ran in the last 30 days get a hint; the fleet's
  # totals cover the last 7.
  @repo_days 30
  @week_days 7
  # MiB-seconds in a GiB-hour.
  @mib_hour 1024 * 3600

  @run_fields [
    :conclusion,
    :vcpus,
    :memory_mib,
    :peak_mem_mib,
    :peak_disk_mib,
    :cpu_excess,
    :cpu_pressure_pct,
    :mem_pressure_pct,
    :mem_full_pressure_pct,
    :oom,
    :coverage,
    :started_at,
    :completed_at
  ]

  @job_fields @run_fields ++
                [:id, :repo_id, :workflow_name, :name, :github_id, :github_run_id, :run_attempt]

  @doc """
  The hint for a finished Crew job, from the latest runs of the same
  (repo, workflow, job name), or nil. Takes a job the caller has already
  read for someone allowed to see it.
  """
  def for_job(%Job{gh_state: "completed", classification: "ours"} = job) do
    case Repos.get(job.repo_id) do
      nil -> nil
      repo -> job |> history() |> Rules.hint(sizes_for(repo))
    end
  end

  def for_job(_job), do: nil

  @doc """
  Every job of `repo` that ran in the last 30 days and has a change to
  suggest, the most memory a run would free first, each with its newest
  run (`job`). Nothing for someone who can't read the repo.
  """
  def for_repo(%Scope{} = scope, repo) do
    if Repos.can_read?(scope, repo.id) do
      [repo.id]
      |> recent_jobs(DateTime.add(DateTime.utc_now(), -@repo_days * 86_400))
      |> job_hints(sizes_for(repo))
      |> Enum.sort_by(&{-&1.hint.saved_mib, &1.workflow_name || "", &1.name || ""})
    else
      []
    end
  end

  @doc """
  The fleet over the last 7 days, for the repos `scope` can read (§7.5):
  the memory its runs reserved and the most they used, in GiB-hours (a
  VM's memory times how long it ran), and what applying the hints would
  have changed over the week's runs: what they free, what they take (a
  larger or faster size), and the net. With each repo's share and every
  hint, the most freed first. `needs_more` counts the jobs whose hint is
  a larger size.

  Archived repos' runs still count toward the week; only live repos get
  hints. Hints look at each job's runs over 30 days, and only runs whose
  summary has the shape they ran on count toward the totals.
  """
  def fleet(%Scope{} = scope, now \\ DateTime.utc_now()) do
    repos = readable(scope)
    live = Enum.filter(repos, &is_nil(&1.archived_at))
    week = week_runs(Enum.map(repos, & &1.id), DateTime.add(now, -@week_days * 86_400))
    sizes = Sizes.list()

    # Each job's seconds this week, by the shape it ran on.
    seconds =
      Enum.reduce(
        week,
        %{},
        &Map.update(&2, job_shape(&1), seconds(&1), fn s -> s + seconds(&1) end)
      )

    by_repo =
      live
      |> Enum.map(& &1.id)
      |> recent_jobs(DateTime.add(now, -@repo_days * 86_400))
      |> Enum.group_by(& &1.repo_id)

    hints =
      for repo <- live,
          h <- job_hints(Map.get(by_repo, repo.id, []), sizes_for(repo, sizes)) do
        key = {repo.id, h.workflow_name, h.name, h.hint.from.vcpus, h.hint.from.memory_mib}

        Map.merge(h, %{
          repo: repo,
          freed_gib_h: h.hint.saved_mib * Map.get(seconds, key, 0) / @mib_hour
        })
      end
      |> Enum.sort_by(
        &{-&1.freed_gib_h, &1.repo.full_name, &1.workflow_name || "", &1.name || ""}
      )

    changes = Enum.group_by(hints, & &1.repo.id)
    week_by_repo = Enum.group_by(week, & &1.repo_id)

    rows =
      for repo <- repos, runs = Map.get(week_by_repo, repo.id, []), runs != [] do
        Map.merge(
          %{
            repo: repo,
            runs: length(runs),
            reserved_gib_h: gib_hours(runs, & &1.memory_mib),
            used_gib_h: gib_hours(runs, & &1.peak_mem_mib)
          },
          change(Map.get(changes, repo.id, []))
        )
      end

    Map.merge(
      %{
        days: @week_days,
        reserved_gib_h: gib_hours(week, & &1.memory_mib),
        used_gib_h: gib_hours(week, & &1.peak_mem_mib),
        needs_more: Enum.count(hints, &(&1.hint.kind == :larger)),
        repos: Enum.sort_by(rows, &{-&1.net_gib_h, -&1.reserved_gib_h, &1.repo.full_name}),
        hints: hints
      },
      change(hints)
    )
  end

  defp readable(scope) do
    case Repos.readable_ids(scope) do
      :all -> Repos.list_all()
      ids -> Enum.filter(Repos.list_all(), &(&1.id in ids))
    end
  end

  defp job_shape(r), do: {r.repo_id, r.workflow_name, r.name, r.vcpus, r.memory_mib}
  defp seconds(r), do: duration(r.started_at, r.completed_at) || 0

  # What a set of hints frees, takes and nets over the week, in GiB-hours.
  defp change(hints) do
    freed = hints |> Enum.map(& &1.freed_gib_h) |> Enum.filter(&(&1 > 0)) |> Enum.sum()
    taken = hints |> Enum.map(& &1.freed_gib_h) |> Enum.filter(&(&1 < 0)) |> Enum.sum()
    %{freed_gib_h: freed * 1.0, taken_gib_h: -taken * 1.0, net_gib_h: (freed + taken) * 1.0}
  end

  # Every finished Crew run of these repos since `since` that has its
  # shape in its summary: few fields, but all of them, since totals add
  # up every run.
  defp week_runs([], _since), do: []

  defp week_runs(repo_ids, since) do
    from(j in Job,
      where:
        j.repo_id in ^repo_ids and j.classification == "ours" and j.gh_state == "completed" and
          j.completed_at >= ^since and not is_nil(j.memory_mib),
      select:
        map(j, [
          :repo_id,
          :workflow_name,
          :name,
          :vcpus,
          :memory_mib,
          :peak_mem_mib,
          :started_at,
          :completed_at
        ])
    )
    |> Repo.all()
  end

  defp gib_hours(runs, mib) do
    runs
    |> Enum.map(fn r -> (mib.(r) || 0) * seconds(r) end)
    |> Enum.sum()
    |> Kernel./(@mib_hour)
  end

  # Each job's latest finished runs (at most @history) in these repos
  # since `since`, newest first: only the fields hints and links read, and
  # the limit applied in the database, since a busy repo runs thousands of
  # jobs a month.
  defp recent_jobs([], _since), do: []

  defp recent_jobs(repo_ids, since) do
    ranked =
      from(j in Job,
        where:
          j.repo_id in ^repo_ids and j.classification == "ours" and j.gh_state == "completed" and
            j.completed_at >= ^since,
        windows: [
          per_job: [
            partition_by: [j.repo_id, j.workflow_name, j.name],
            order_by: [desc: j.completed_at, desc: j.id]
          ]
        ],
        select: %{id: j.id, rank: over(row_number(), :per_job)}
      )

    from(j in Job,
      join: r in subquery(ranked),
      on: r.id == j.id and r.rank <= ^@history,
      order_by: [desc: j.completed_at, desc: j.id],
      select: map(j, ^@job_fields)
    )
    |> Repo.all()
  end

  # A hint for each (workflow, name) among `jobs` (newest first) with a
  # change to suggest, with its newest run.
  defp job_hints(jobs, sizes) do
    jobs
    |> Enum.group_by(&{&1.workflow_name, &1.name})
    |> Enum.flat_map(fn {{workflow, name}, [newest | _] = runs} ->
      case runs |> Enum.map(&run/1) |> Rules.hint(sizes) do
        %{kind: kind} = hint when kind != :fits ->
          [%{workflow_name: workflow, name: name, hint: hint, job: newest}]

        _ ->
          []
      end
    end)
  end

  defp history(%Job{} = job) do
    from(j in Job,
      where:
        j.repo_id == ^job.repo_id and j.workflow_name == ^job.workflow_name and
          j.name == ^job.name and j.classification == "ours" and j.gh_state == "completed",
      order_by: [desc: j.completed_at, desc: j.id],
      limit: @history,
      select: map(j, ^@run_fields)
    )
    |> Repo.all()
    |> Enum.map(&run/1)
  end

  defp run(job) do
    job
    |> Map.take(@run_fields)
    |> Map.put(:duration_s, duration(job.started_at, job.completed_at))
  end

  defp duration(%DateTime{} = a, %DateTime{} = b), do: DateTime.diff(b, a)
  defp duration(_a, _b), do: nil

  @doc "The sizes a repo may use: not retired, and allowed if it limits them (§7.4)."
  def sizes_for(repo, sizes \\ Sizes.list()) do
    for s <- sizes,
        is_nil(s.retired_at),
        repo.allowed_sizes in [nil, []] or s.name in repo.allowed_sizes,
        do: %{name: s.name, vcpus: s.vcpus, memory_mib: s.memory_mib, disk_gib: s.disk_gib}
  end
end
