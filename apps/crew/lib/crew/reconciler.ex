defmodule Crew.Reconciler do
  @moduledoc """
  Reconciliation with GitHub (§8.8), on its own queue (`reconcile`,
  concurrency 1). Its calls are essential (§6.6).

  - **Queued jobs** are re-checked 90 s after their last event, then
    every 5 minutes, by fetching their run attempt's jobs: one call per
    run attempt, never per job. A check is skipped while webhooks for
    the repo arrived within the last 5 minutes and the job itself had one
    within its check interval.
  - **Busy VMs** whose job has had no event for 15 minutes are checked
    the same way, then every 5 minutes.
  - **Missed jobs:** every 5 minutes, each enabled repo with Crew jobs in
    the last 7 days has its queued and in-progress runs listed, and any
    job Crew doesn't know is added.
  - **Poll-only mode** (`CREW_WEBHOOKS=off`): the sweep is the only
    intake, so it covers every enabled repo, at an interval the budget
    allows (`poll_interval/2`); repos idle for an hour every 5 minutes.

  `Crew.Reconciler.Ticker` queues a run every 15 s; each run does only
  what's due.
  """
  use Oban.Worker,
    queue: :reconcile,
    max_attempts: 1,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  require Logger

  alias Crew.{Jobs, Repo, Repos}
  alias Crew.GitHub.Client
  alias Crew.Jobs.Job
  alias Crew.Repos.Repo, as: GitRepo

  @first_check_s 90
  @busy_quiet_s 900
  @recheck_s 300
  @webhook_quiet_s 300
  @sweep_s 300
  @active_window_s 3600
  @recent_days 7

  @impl true
  def perform(_job) do
    check_queued()
    if sweep_due?(), do: sweep_missed()
    :ok
  end

  # -- queued jobs ---------------------------------------------------------

  @doc "Re-checks the queued jobs that are due."
  def check_queued do
    now = DateTime.utc_now()
    first_cutoff = DateTime.add(now, -@first_check_s)

    candidates =
      Repo.all(
        from j in Job,
          join: r in assoc(j, :repo),
          where:
            j.gh_state == "queued" and j.classification in ["ours", "unsatisfiable"] and
              j.last_event_at <= ^first_cutoff,
          preload: [repo: {r, :installation}]
      )

    (candidates ++ quiet_busy_jobs(now))
    |> Enum.filter(&due?(&1, now))
    |> Enum.reject(&skip?(&1, now))
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(&{&1.repo_id, &1.github_run_id, &1.run_attempt})
    |> Enum.each(fn {{_, run_id, attempt}, jobs} ->
      recheck(hd(jobs).repo, run_id, attempt, jobs, now)
    end)

    :ok
  end

  # Busy VMs whose job has had no event for 15 minutes (§8.8): the job
  # may have finished with its webhook lost.
  defp quiet_busy_jobs(now) do
    cutoff = DateTime.add(now, -@busy_quiet_s)

    Repo.all(
      from j in Job,
        join: v in Crew.VMs.VM,
        on: v.job_id == j.id and v.state == "busy",
        join: r in assoc(j, :repo),
        where: j.gh_state == "in_progress" and j.last_event_at <= ^cutoff,
        preload: [repo: {r, :installation}]
    )
  end

  defp due?(%Job{checked_at: nil}, _now), do: true
  defp due?(%Job{checked_at: at}, now), do: DateTime.diff(now, at) >= @recheck_s

  defp skip?(%Job{} = job, now) do
    interval = if job.checked_at, do: @recheck_s, else: @first_check_s
    repo_busy? = recent?(job.repo.last_activity_at, now, @webhook_quiet_s)
    repo_busy? and recent?(job.last_event_at, now, interval)
  end

  defp recent?(nil, _now, _s), do: false
  defp recent?(at, now, s), do: DateTime.diff(now, at) < s

  defp recheck(repo, run_id, attempt, jobs, now) do
    case Client.list_attempt_jobs(repo.installation.github_id, repo.full_name, run_id, attempt) do
      {:ok, listed} ->
        Enum.each(listed, &Jobs.upsert_job(repo, &1, source: "api", kind: "reconcile"))

      error ->
        Logger.warning("reconciling #{repo.full_name} run #{run_id}: #{inspect(error)}")
    end

    # Checked either way: a failing GitHub is tried again in 5 minutes,
    # not every pass.
    ids = Enum.map(jobs, & &1.id)
    Repo.update_all(from(j in Job, where: j.id in ^ids), set: [checked_at: now])
  end

  # -- missed jobs ---------------------------------------------------------------

  # Monotonic time can be negative, so "never swept" is nil, not 0.
  defp sweep_due? do
    case :persistent_term.get({__MODULE__, :swept_at}, nil) do
      nil -> true
      last -> System.monotonic_time(:second) - last >= sweep_interval()
    end
  end

  defp sweep_interval do
    if Application.get_env(:crew, :webhooks, true) do
      @sweep_s
    else
      poll_interval(length(active_repos()), hourly_limit())
    end
  end

  defp hourly_limit do
    Repos.list_installations()
    |> Enum.map(&(Crew.GitHub.Budget.info(&1.github_id).limit || 5000))
    |> Enum.min(fn -> 5000 end)
  end

  @doc """
  The poll-only sweep interval in seconds (§8.8):
  `max(15, ⌈3600 × calls_per_sweep × active_repos ÷ (0.3 × hourly_limit)⌉)`,
  with about 3 calls per sweep (two run lists, plus their jobs).
  """
  def poll_interval(active_repos, hourly_limit) do
    max(15, ceil(3600 * 3 * active_repos / (0.3 * hourly_limit)))
  end

  @doc "Sweeps for jobs Crew doesn't know. `{:ok, %{repos:, added:}}`."
  def sweep_missed do
    :persistent_term.put({__MODULE__, :swept_at}, System.monotonic_time(:second))

    repos =
      if Application.get_env(:crew, :webhooks, true),
        do: repos_with_recent_jobs(),
        else: repos_due_for_polling()

    added = repos |> Enum.map(&sweep_repo/1) |> Enum.sum()
    {:ok, %{repos: length(repos), added: added}}
  end

  defp repos_with_recent_jobs do
    since = DateTime.add(DateTime.utc_now(), -@recent_days * 86_400)

    Repo.all(
      from r in GitRepo,
        as: :repo,
        where:
          r.enabled and is_nil(r.archived_at) and
            exists(
              from j in Job,
                where:
                  j.repo_id == parent_as(:repo).id and j.classification == "ours" and
                    j.seen_at > ^since
            ),
        preload: :installation
    )
  end

  # Poll-only: every enabled repo. Active ones every pass; ones idle for
  # an hour every 5 minutes.
  defp repos_due_for_polling do
    now = DateTime.utc_now()

    idle_due? =
      case :persistent_term.get({__MODULE__, :idle_swept_at}, nil) do
        nil -> true
        last -> System.monotonic_time(:second) - last >= @sweep_s
      end

    if idle_due?,
      do: :persistent_term.put({__MODULE__, :idle_swept_at}, System.monotonic_time(:second))

    Repo.all(
      from r in GitRepo, where: r.enabled and is_nil(r.archived_at), preload: :installation
    )
    |> Enum.filter(fn r -> idle_due? or recent?(r.last_activity_at, now, @active_window_s) end)
  end

  defp active_repos do
    cutoff = DateTime.add(DateTime.utc_now(), -@active_window_s)

    Repo.all(
      from r in GitRepo,
        where: r.enabled and is_nil(r.archived_at) and r.last_activity_at > ^cutoff,
        select: r.id
    )
  end

  defp sweep_repo(repo) do
    inst = repo.installation.github_id

    ["queued", "in_progress"]
    |> Enum.flat_map(fn status ->
      case Client.list_runs(inst, repo.full_name, status) do
        {:ok, runs} -> runs
        error -> Logger.warning("sweeping #{repo.full_name}: #{inspect(error)}") && []
      end
    end)
    |> Enum.uniq_by(&{&1["id"], &1["run_attempt"]})
    |> Enum.map(&sweep_run(repo, &1))
    |> Enum.sum()
  end

  defp sweep_run(repo, run) do
    {:ok, _} = Jobs.upsert_run_attempt(repo, run)
    attempt = run["run_attempt"] || 1

    case Client.list_attempt_jobs(repo.installation.github_id, repo.full_name, run["id"], attempt) do
      {:ok, jobs} ->
        Enum.count(jobs, fn data ->
          if is_nil(Jobs.get_job_by_github_id(data["id"])) do
            match?({:ok, _}, Jobs.upsert_job(repo, data, source: "api", kind: "sweep"))
          end
        end)

      error ->
        Logger.warning("sweeping #{repo.full_name} run #{run["id"]}: #{inspect(error)}")
        0
    end
  end
end
