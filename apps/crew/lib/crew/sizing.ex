defmodule Crew.Sizing do
  @moduledoc """
  Right-sizing hints (§7.5) for a job, a repo's jobs and the fleet: reads
  each job's latest runs (its summaries, §16.5) and the sizes its repo may
  use, and asks `Crew.Sizing.Rules`.

  Display only. Nothing here changes placement, labels or sizes. Admins
  can dismiss a hint (`dismiss/3`): it stays on its repo's page, marked,
  and leaves the fleet's hints and totals.
  """
  import Ecto.Query

  alias Crew.{Audit, Repo, Repos, Scope, Sizes}
  alias Crew.Jobs.{Job, RunAttempt}
  alias Crew.Sizing.{CriticalPath, Dismissal, Rules}
  alias Crew.Sizing.Rules.Hint

  # Rows read per job: more than the rules' window, since only the runs
  # on the newest one's shape count.
  @history 30
  # A repo's jobs that ran in the last 30 days get a hint; the fleet's
  # totals cover the last 7.
  @repo_days 30
  @week_days 7
  @durations_days 90
  # MiB-seconds in a GiB-hour.
  @mib_hour 1024 * 3600
  # A move to a new size is slower when its median run is this much longer.
  @slower 1.05

  @run_fields [
    :id,
    :run_attempt_id,
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
                [
                  :repo_id,
                  :workflow_name,
                  :name,
                  :github_id,
                  :github_run_id,
                  :run_attempt,
                  :labels,
                  :arch,
                  :spare
                ]

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
  How long a finished job's successful runs took on each shape they ran
  on, the median of each, smallest shape first (§7.5): the check that a
  new size didn't slow it down. Crew counts reclaimable page cache as
  free, so a job that reads a lot can get slower on less memory without
  running out. From its last 30 successful runs within 90 days. Empty for
  a job still running, or with one shape to go on.
  """
  def durations(%Job{gh_state: "completed", classification: "ours"} = job) do
    runs =
      job
      |> shaped_successes()
      |> Enum.map(&{{&1.vcpus, &1.memory_mib}, duration(&1.started_at, &1.completed_at)})
      |> Enum.filter(fn {_, d} -> is_integer(d) and d >= 0 end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    if map_size(runs) < 2, do: [], else: medians(runs)
  end

  def durations(_job), do: []

  # The job's last successful runs whose summary has their shape, bounded
  # in time as well as count: a job with years of runs from before
  # summaries kept a shape would otherwise be read in full.
  defp shaped_successes(job) do
    since = DateTime.add(DateTime.utc_now(), -@durations_days * 86_400)

    from(j in Job,
      where:
        j.repo_id == ^job.repo_id and j.classification == "ours" and j.gh_state == "completed" and
          j.completed_at >= ^since and j.conclusion == "success" and not is_nil(j.vcpus) and
          not is_nil(j.memory_mib),
      order_by: [desc: j.completed_at, desc: j.id],
      limit: @history,
      select: map(j, [:vcpus, :memory_mib, :started_at, :completed_at])
    )
    |> same_job(job)
    |> Repo.all()
  end

  defp medians(runs) do
    sizes = Sizes.list()

    runs
    |> Enum.map(fn {{vcpus, memory}, ds} ->
      name = Enum.find_value(sizes, &(&1.vcpus == vcpus and &1.memory_mib == memory and &1.name))

      %{
        shape: %{name: name, vcpus: vcpus, memory_mib: memory},
        runs: length(ds),
        median_s: ds |> Enum.sort() |> Enum.at(div(length(ds), 2))
      }
    end)
    |> Enum.sort_by(&{&1.shape.memory_mib, &1.shape.vcpus})
  end

  @doc """
  Every job of `repo` that ran in the last 30 days and has a change to
  suggest, the most memory a run would free first, each with its newest
  run (`job`), that run's workflow file as GitHub gives it
  (`workflow_path`, nil when Crew doesn't know it), and its `dismissal`
  (nil unless an admin dismissed it). Nothing for someone who can't read
  the repo.
  """
  def for_repo(%Scope{} = scope, repo) do
    if Repos.can_read?(scope, repo.id) do
      [repo.id]
      |> recent_jobs(DateTime.add(DateTime.utc_now(), -@repo_days * 86_400))
      |> job_hints(sizes_for(repo))
      |> put_dismissals(repo.id)
      |> Enum.sort_by(&{-&1.hint.saved_mib, &1.workflow_name || "", &1.name || ""})
    else
      []
    end
  end

  @doc """
  Dismisses a job's hint (admins), with an optional `"reason"`: the hint
  for the job's (repo, workflow, name) that the page showed, by its
  `"kind"` and the shape it's from (`"vcpus"`, `"memory_mib"`), as a
  dismiss form sends them. Dismissing it again keeps one, with the newer
  reason. `{:error, :changed}` when the job's hint isn't that one any
  more, on its page or in the lists: a form left open while a run came
  in dismisses nothing.
  """
  def dismiss(%Scope{} = scope, job_id, %{} = shown) do
    with :ok <- authorize(scope),
         {:ok, job} <- fetch(Job, job_id),
         {:ok, hint} <- still_shown(job, shown) do
      {repo_id, workflow, name, vcpus, memory, kind} =
        Dismissal.key(job.repo_id, job.workflow_name, job.name, hint.from, hint.kind)

      %Dismissal{
        repo_id: repo_id,
        workflow_name: workflow,
        job_name: name,
        vcpus: vcpus,
        memory_mib: memory,
        kind: kind,
        user_id: Scope.user_id(scope),
        user_login: scope.user && scope.user.login
      }
      |> Dismissal.changeset(%{reason: shown["reason"]})
      |> Repo.insert(
        on_conflict: {:replace, [:reason, :user_id, :user_login, :updated_at]},
        conflict_target: [:repo_id, :workflow_name, :job_name, :vcpus, :memory_mib, :kind],
        returning: true
      )
      |> logged(scope, "sizing_hint.dismiss")
    end
  end

  @doc "Brings a dismissed hint back (admins)."
  def restore(%Scope{} = scope, dismissal_id) do
    with :ok <- authorize(scope),
         {:ok, dismissal} <- fetch(Dismissal, dismissal_id) do
      dismissal |> Repo.delete() |> logged(scope, "sizing_hint.restore")
    end
  end

  @doc "The dismissal of a job's hint (from `for_job/1`), for its page, or nil."
  def dismissal(_job, nil), do: nil

  def dismissal(%Job{} = job, %Hint{} = hint) do
    {repo_id, workflow, name, vcpus, memory, kind} =
      Dismissal.key(job.repo_id, job.workflow_name, job.name, hint.from, hint.kind)

    Repo.get_by(Dismissal,
      repo_id: repo_id,
      workflow_name: workflow,
      job_name: name,
      vcpus: vcpus,
      memory_mib: memory,
      kind: kind
    )
  end

  defp authorize(scope), do: if(Scope.admin?(scope), do: :ok, else: {:error, :unauthorized})

  defp fetch(schema, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %{} = row <- Repo.get(schema, id) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  # The job's hint that matches what the page showed: its page's (from
  # the job's latest runs) or the lists' (from those of the last 30 days).
  defp still_shown(job, shown) do
    key = {shown["kind"], int(shown["vcpus"]), int(shown["memory_mib"])}

    [&for_job/1, &listed/1]
    |> Enum.find_value(fn hint_of ->
      case hint_of.(job) do
        %Hint{kind: kind, from: from} = hint when kind != :fits ->
          if {to_string(kind), from.vcpus, from.memory_mib} == key, do: hint

        _ ->
          nil
      end
    end)
    |> case do
      nil -> {:error, :changed}
      hint -> {:ok, hint}
    end
  end

  defp int(n) when is_integer(n), do: n

  defp int(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  # A job's hint as the repo and fleet lists have it, or nil.
  defp listed(%Job{} = job) do
    case Repos.get(job.repo_id) do
      nil ->
        nil

      repo ->
        [job.repo_id]
        |> recent_jobs(DateTime.add(DateTime.utc_now(), -@repo_days * 86_400), job)
        |> job_hints(sizes_for(repo))
        |> Enum.find_value(& &1.hint)
    end
  end

  defp logged({:ok, %Dismissal{} = d} = ok, scope, action) do
    repo = Repos.get(d.repo_id)

    Audit.log(scope, action, d, %{
      "repo" => repo && repo.full_name,
      "job" => "#{d.workflow_name} · #{d.job_name}",
      "kind" => d.kind,
      "shape" => "#{d.vcpus} vCPU · #{Float.round(d.memory_mib / 1024, 1)} GiB",
      "reason" => d.reason
    })

    ok
  end

  defp logged(error, _scope, _action), do: error

  # Each hint with its dismissal, from those of `repo_ids` (or one), read
  # at once. A hint's repo is its own `repo`, or the one repo.
  defp put_dismissals(hints, repo_ids) do
    dismissals =
      from(d in Dismissal, where: d.repo_id in ^List.wrap(repo_ids))
      |> Repo.all()
      |> Map.new(&{Dismissal.key(&1), &1})

    Enum.map(hints, fn h ->
      repo_id = if h[:repo], do: h.repo.id, else: repo_ids
      key = Dismissal.key(repo_id, h.workflow_name, h.name, h.hint.from, h.hint.kind)
      Map.put(h, :dismissal, Map.get(dismissals, key))
    end)
  end

  @doc """
  The fleet over the last 7 days, for the repos `scope` can read (§7.5):
  the memory its runs reserved and the most they used, in GiB-hours (a
  VM's memory times how long it ran), and what applying the hints would
  have changed over the week's runs: what they free, what they take (a
  larger or faster size), and the net. With each repo's share and every
  hint, the most freed first. `needs_more` counts the jobs whose hint is
  a larger size. Dismissed hints count toward none of it; they're apart,
  in `dismissed`, each with its `dismissal`. `custom` groups the custom
  hints by the shape they'd fit, each with its hints and what they'd
  free in the week, the most first: one size for an admin to add where
  several jobs would use it.

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

    {dismissed, hints} =
      for repo <- live,
          h <- job_hints(Map.get(by_repo, repo.id, []), sizes_for(repo, sizes)) do
        key = {repo.id, h.workflow_name, h.name, h.hint.from.vcpus, h.hint.from.memory_mib}

        Map.merge(h, %{
          repo: repo,
          freed_gib_h: h.hint.saved_mib * Map.get(seconds, key, 0) / @mib_hour
        })
      end
      |> put_dismissals(Enum.map(live, & &1.id))
      |> Enum.sort_by(
        &{-&1.freed_gib_h, &1.repo.full_name, &1.workflow_name || "", &1.name || ""}
      )
      |> Enum.split_with(& &1.dismissal)

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
        hints: hints,
        dismissed: dismissed,
        custom: custom_shapes(hints)
      },
      change(hints)
    )
  end

  defp custom_shapes(hints) do
    hints
    |> Enum.filter(&(&1.hint.kind == :custom))
    |> Enum.group_by(&Map.take(&1.hint.to, [:vcpus, :memory_mib, :disk_gib]))
    |> Enum.map(fn {shape, hints} ->
      %{
        shape: shape,
        hints: hints,
        freed_gib_h: hints |> Enum.map(& &1.freed_gib_h) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{-&1.freed_gib_h, &1.shape.memory_mib, &1.shape.vcpus})
  end

  @doc """
  The jobs whose size changed in the last 30 days, for the repos `scope`
  can read (§7.5): the shape before (`from`) and now (`to`), when the
  first run on the new one started (`changed_at`), how many runs each
  had (`runs_before`, from 90 days back; `runs_after`), the median
  duration of the successful ones on each (the newest 30), and what the
  move freed (or took, negative) in GiB-hours over the week's runs. A
  move went badly when the median is over 5% longer (`slower`) or a run
  on the new size had a process killed for memory (`ooms`). Those come
  first, then the newest.

  A job's newest run (`job`) sets its size; its change is the first run
  on that size after the last run on another. Archived repos are left
  out.
  """
  def changes(%Scope{} = scope, now \\ DateTime.utc_now()) do
    repos = scope |> readable() |> Enum.filter(&is_nil(&1.archived_at))
    ids = Enum.map(repos, & &1.id)
    by_id = Map.new(repos, &{&1.id, &1})
    since = DateTime.add(now, -@repo_days * 86_400)
    far = DateTime.add(now, -@durations_days * 86_400)
    sizes = Sizes.list()
    week = DateTime.add(now, -@week_days * 86_400)

    newest =
      ids
      |> recent_jobs(since, nil, 1)
      |> Enum.filter(&(is_integer(&1.vcpus) and is_integer(&1.memory_mib)))

    last_other = last_other_shapes(newest, far)

    newest
    |> Enum.flat_map(fn job ->
      case Map.get(last_other, job.id) do
        nil -> []
        old -> change(job, old, since, far, sizes, week, by_id)
      end
    end)
    |> Enum.sort_by(&{not (&1.slower or &1.ooms > 0), -DateTime.to_unix(&1.changed_at)})
  end

  # For each of `newest` (a job's newest run) with a run on another shape
  # since `far`, the newest such run: its shape, and when it finished and
  # its id, which order runs that finish in the same second.
  defp last_other_shapes([], _far), do: %{}

  defp last_other_shapes(newest, far) do
    newest
    |> Enum.map(& &1.id)
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn ids ->
      other =
        from(j in Job,
          join: n in Job,
          on: ^same_job_as_newest(ids),
          where: ^on_another_shape(far),
          windows: [per_job: [partition_by: n.id, order_by: [desc: j.completed_at, desc: j.id]]],
          select: %{
            newest: n.id,
            vcpus: j.vcpus,
            memory_mib: j.memory_mib,
            completed_at: j.completed_at,
            id: j.id,
            rank: over(row_number(), :per_job)
          }
        )

      Repo.all(from o in subquery(other), where: o.rank == 1)
    end)
    |> Map.new(&{&1.newest, &1})
  end

  # A run (`j`) of the same job as one of the newest runs `ids` (`n`):
  # its repo, workflow and name, either of which may be null.
  defp same_job_as_newest(ids) do
    dynamic(
      [j, n],
      n.id in ^ids and n.repo_id == j.repo_id and
        (n.name == j.name or (is_nil(n.name) and is_nil(j.name))) and
        (n.workflow_name == j.workflow_name or
           (is_nil(n.workflow_name) and is_nil(j.workflow_name)))
    )
  end

  # A finished Crew run since `far` whose shape isn't the newest run's.
  defp on_another_shape(far) do
    dynamic(
      [j, n],
      j.classification == "ours" and j.gh_state == "completed" and j.completed_at >= ^far and
        not is_nil(j.vcpus) and not is_nil(j.memory_mib) and
        (j.vcpus != n.vcpus or j.memory_mib != n.memory_mib)
    )
  end

  defp change(job, old, since, far, sizes, week, by_id) do
    now_shape = %{vcpus: job.vcpus, memory_mib: job.memory_mib}
    was_shape = %{vcpus: old.vcpus, memory_mib: old.memory_mib}
    # After the last run on the old shape, in the order runs are ranked.
    later =
      runs_on(job, now_shape)
      |> where(
        [j],
        j.completed_at > ^old.completed_at or
          (j.completed_at == ^old.completed_at and j.id > ^old.id)
      )

    with %DateTime{} = changed_at <- Repo.one(from j in later, select: min(j.started_at)),
         false <- DateTime.compare(changed_at, since) == :lt do
      earlier =
        runs_on(job, was_shape)
        |> where([j], j.completed_at >= ^far and j.completed_at <= ^old.completed_at)

      {runs_after, ooms} =
        Repo.one(
          from j in later,
            select: {count(j.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", j.oom))}
        )

      before_s = median_success(earlier)
      after_s = median_success(later)

      [
        %{
          repo: Map.fetch!(by_id, job.repo_id),
          workflow_name: job.workflow_name,
          name: job.name,
          job: job,
          from: named(was_shape, sizes),
          to: named(now_shape, sizes),
          changed_at: changed_at,
          runs_before: Repo.aggregate(earlier, :count),
          runs_after: runs_after,
          median_before_s: before_s,
          median_after_s: after_s,
          slower: is_integer(before_s) and is_integer(after_s) and after_s > before_s * @slower,
          ooms: ooms || 0,
          freed_gib_h: (old.memory_mib - job.memory_mib) * seconds_since(later, week) / @mib_hour
        }
      ]
    else
      _ -> []
    end
  end

  # How long `runs` that finished since `since` ran, all told.
  defp seconds_since(runs, since) do
    from(j in runs, where: j.completed_at >= ^since, select: {j.started_at, j.completed_at})
    |> Repo.all()
    |> Enum.map(fn {a, b} -> max(duration(a, b) || 0, 0) end)
    |> Enum.sum()
  end

  # A job's finished Crew runs on a shape.
  defp runs_on(job, %{vcpus: vcpus, memory_mib: memory}) do
    from(j in Job,
      where:
        j.repo_id == ^job.repo_id and j.classification == "ours" and j.gh_state == "completed" and
          j.vcpus == ^vcpus and j.memory_mib == ^memory
    )
    |> same_job(job)
  end

  # The median duration of the newest 30 successful runs among `runs`.
  defp median_success(runs) do
    from(j in runs,
      where: j.conclusion == "success",
      order_by: [desc: j.completed_at, desc: j.id],
      limit: @history,
      select: {j.started_at, j.completed_at}
    )
    |> Repo.all()
    |> Enum.map(fn {a, b} -> duration(a, b) end)
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> case do
      [] -> nil
      ds -> ds |> Enum.sort() |> Enum.at(div(length(ds), 2))
    end
  end

  defp named(%{vcpus: vcpus, memory_mib: memory} = shape, sizes),
    do:
      Map.put(
        shape,
        :name,
        Enum.find_value(sizes, &(&1.vcpus == vcpus and &1.memory_mib == memory and &1.name))
      )

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
  # since `since`, newest first: only the fields hints and links read
  # (with the run's workflow file), and the limit applied in the
  # database, since a busy repo runs thousands of jobs a month. Only
  # those of `job`'s (workflow, name), given one.
  defp recent_jobs(repo_ids, since, job \\ nil, limit \\ @history)
  defp recent_jobs([], _since, _job, _limit), do: []

  defp recent_jobs(repo_ids, since, job, limit) do
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
      |> then(&if(job, do: same_job(&1, job), else: &1))

    from(j in Job,
      join: r in subquery(ranked),
      on: r.id == j.id and r.rank <= ^limit,
      left_join: a in RunAttempt,
      on: a.id == j.run_attempt_id,
      order_by: [desc: j.completed_at, desc: j.id],
      select: merge(map(j, ^@job_fields), %{workflow_path: a.workflow_path})
    )
    |> Repo.all()
  end

  # A hint for each (workflow, name) among `jobs` (newest first) with a
  # change to suggest, with its newest run and that run's workflow file.
  defp job_hints(jobs, sizes) do
    groups = jobs |> Enum.group_by(&{&1.workflow_name, &1.name}) |> Map.values()

    groups
    |> Enum.map(fn group -> Enum.map(group, &run/1) end)
    |> trace()
    |> Enum.zip(groups)
    |> Enum.flat_map(fn {runs, [newest | _]} ->
      case Rules.hint(runs, sizes) do
        %{kind: kind} = hint when kind != :fits ->
          [
            %{
              workflow_name: newest.workflow_name,
              name: newest.name,
              workflow_path: newest.workflow_path,
              hint: hint,
              job: newest
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp history(%Job{} = job) do
    from(j in Job,
      where:
        j.repo_id == ^job.repo_id and j.classification == "ours" and j.gh_state == "completed",
      order_by: [desc: j.completed_at, desc: j.id],
      limit: @history,
      select: map(j, ^@run_fields)
    )
    |> same_job(job)
    |> Repo.all()
    |> Enum.map(&run/1)
    |> then(&hd(trace([&1])))
  end

  # Marks the runs a hint counts that waited on a CPU, in each job's runs
  # (`groups`), with whether they were on their run attempt's critical
  # path (`critical`; absent when that can't be told): the hints that add
  # vCPUs ask. Reads those attempts' jobs only.
  defp trace(groups) do
    paths =
      paths(
        for runs <- groups,
            r <- Rules.counted_runs(runs),
            Rules.starved?(r),
            r.run_attempt_id,
            uniq: true,
            do: r.run_attempt_id
      )

    for runs <- groups do
      Enum.map(runs, fn r ->
        case Map.get(paths, r.run_attempt_id) do
          %MapSet{} = path -> Map.put(r, :critical, MapSet.member?(path, r.id))
          nil -> r
        end
      end)
    end
  end

  # Each run attempt's critical path, by id, a chunk of attempts a query.
  defp paths(attempt_ids) do
    attempt_ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn ids ->
      from(j in Job,
        where: j.run_attempt_id in ^ids,
        select: map(j, [:id, :run_attempt_id, :queued_at, :started_at, :completed_at])
      )
      |> Repo.all()
    end)
    |> Enum.group_by(& &1.run_attempt_id)
    |> Map.new(fn {attempt, jobs} -> {attempt, CriticalPath.ids(jobs)} end)
  end

  defp run(job) do
    job
    |> Map.take(@run_fields)
    |> Map.put(:duration_s, duration(job.started_at, job.completed_at))
  end

  # The runs of `job`'s (workflow, name), either of which GitHub may
  # leave out: SQL's `=` never matches a null.
  defp same_job(query, job),
    do: query |> same(:workflow_name, job.workflow_name) |> same(:name, job.name)

  defp same(query, field, nil), do: where(query, [j], is_nil(field(j, ^field)))
  defp same(query, field, value), do: where(query, [j], field(j, ^field) == ^value)

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
