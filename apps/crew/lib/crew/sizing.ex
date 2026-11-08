defmodule Crew.Sizing do
  @moduledoc """
  Right-sizing hints (§7.5) for a job and for a repo's jobs: reads each
  job's latest runs (its summaries, §16.5) and the sizes its repo may use,
  and asks `Crew.Sizing.Rules`.

  Display only. Nothing here changes placement, labels or sizes.
  """
  import Ecto.Query

  alias Crew.{Repo, Repos, Scope, Sizes}
  alias Crew.Jobs.Job
  alias Crew.Sizing.Rules

  # Rows read per job: more than the rules' window, since only the runs
  # on the newest one's shape count.
  @history 30
  # A repo's jobs that ran in the last 30 days get a hint.
  @repo_days 30

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

  # Each job's latest finished runs (at most @history) in these repos
  # since `since`, newest first: only the fields hints and links read, and
  # the limit applied in the database, since a busy repo runs thousands of
  # jobs a month.
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
  def sizes_for(repo) do
    for s <- Sizes.list(),
        is_nil(s.retired_at),
        repo.allowed_sizes in [nil, []] or s.name in repo.allowed_sizes,
        do: %{name: s.name, vcpus: s.vcpus, memory_mib: s.memory_mib, disk_gib: s.disk_gib}
  end
end
