defmodule Crew.Jobs do
  @moduledoc """
  Run attempts, jobs and their events (§8.2, §6.4).

  A job's `gh_state` only moves forward, `waiting < queued < in_progress
  < completed`. Every upsert is one conditional statement, so concurrent
  webhook workers can't move a job backwards; an event for an earlier
  state is recorded in `job_events` and otherwise ignored.

  Changes are broadcast with ids only (§9.3): `{:job_changed, id}` on
  `jobs`, `job:<id>` and `repo:<repo_id>`; `{:run_changed, id}` on `jobs`,
  `run:<id>` and `repo:<repo_id>`.
  """
  import Ecto.Query

  require Logger

  alias Crew.{Audit, Repo, Repos, Sizes}
  alias Crew.Jobs.{CancelRun, Classify, FetchRunAttempt, Insights, Job, JobEvent, RunAttempt}
  alias Crew.Repos.Repo, as: GitRepo

  @checking_fork "checking fork status"

  def checking_fork, do: @checking_fork

  # -- reads --------------------------------------------------------------------

  def get_job(id), do: Repo.get(Job, id)
  def get_job!(id), do: Repo.get!(Job, id)
  def get_job_by_github_id(id), do: Repo.get_by(Job, github_id: id)
  def get_run_attempt(id), do: Repo.get(RunAttempt, id)

  @doc "The newest job GitHub gave the named runner."
  def find_by_runner_name(name) when is_binary(name) do
    Repo.one(
      from j in Job,
        where: j.runner_name == ^name,
        order_by: [desc: j.started_at, desc: j.inserted_at],
        limit: 1
    )
  end

  @doc """
  Links a job to the VM that took it. A job taken by a runner booted for
  another class is flagged `taken_cross_class` (§8.1).
  """
  def link_vm(job_id, %{id: vm_id, class_key: key}) do
    with %Job{} = job <- get_job(job_id) do
      cross = job.label_key != key

      job =
        job
        |> Ecto.Changeset.change(vm_id: vm_id, taken_cross_class: cross, wait_reason: nil)
        |> Repo.update!()

      # Linked after its `completed`: the summary couldn't be written then.
      if job.gh_state == "completed" and is_nil(job.peak_mem_mib), do: summarize(job)
      job = if job.gh_state == "completed", do: get_job(job.id), else: job

      broadcast_job(job)
      {:ok, job}
    end
  end

  def list_events(%Job{id: id}) do
    Repo.all(from e in JobEvent, where: e.job_id == ^id, order_by: [asc: e.at, asc: e.id])
  end

  def list_attempt_jobs(%RunAttempt{id: id}) do
    Repo.all(from j in Job, where: j.run_attempt_id == ^id, order_by: [asc: j.github_id])
  end

  # -- runs (§17.3) ------------------------------------------------------------

  @page 50

  @doc """
  The latest attempt of each run, newest first, that `scope` may see,
  with `filters` (`repo`, `q`, `status`, `crew`, `mine`) and keyset
  pagination (`before:` an attempt id). Each comes with its repo, its
  jobs and the numbers of its earlier attempts.

  `q` is a search where every word has to match. A bare word matches
  part of the branch or the actor in any case (ASCII case only on
  SQLite), or the PR when it's a number; `#718` matches only the PR. `branch:`, `actor:` and `pr:`
  match that field exactly, actors in any case. `crew` keeps runs with
  a job for Crew, runnable or not.
  """
  def list_runs(%Crew.Scope{} = scope, filters \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, @page)

    latest =
      from a in RunAttempt,
        as: :attempt,
        where:
          not exists(
            from later in RunAttempt,
              where:
                later.github_run_id == parent_as(:attempt).github_run_id and
                  later.run_attempt > parent_as(:attempt).run_attempt
          )

    latest
    |> readable(scope)
    |> apply_filters(filters, scope)
    |> then(fn q ->
      case opts[:before] do
        nil -> q
        id -> where(q, [a], a.id < ^id)
      end
    end)
    |> order_by([a], desc: a.id)
    |> limit(^limit)
    |> preload([:repo, :jobs])
    |> Repo.all()
    |> Enum.map(&with_earlier_attempts/1)
  end

  defp readable(query, scope) do
    case Repos.readable_ids(scope) do
      :all -> query
      ids -> where(query, [a], a.repo_id in ^ids)
    end
  end

  defp apply_filters(query, filters, scope) do
    Enum.reduce(filters, query, fn
      {"repo", name}, q when is_binary(name) and name != "" ->
        join(q, :inner, [a], r in assoc(a, :repo), on: r.full_name == ^name)

      {"repo_id", id}, q when is_binary(id) ->
        where(q, [a], a.repo_id == ^id)

      {"q", search}, q when is_binary(search) ->
        search |> String.split() |> Enum.reduce(q, &search_term/2)

      {"crew", "true"}, q ->
        where(
          q,
          [a],
          exists(
            from j in Job,
              where:
                j.run_attempt_id == parent_as(:attempt).id and
                  j.classification in ["ours", "unsatisfiable"]
          )
        )

      {"status", status}, q when status in ["queued", "in_progress", "completed"] ->
        where(q, [a], a.status == ^status)

      {"status", status}, q when status in ["success", "failure", "cancelled"] ->
        where(q, [a], a.conclusion == ^status)

      {"mine", "true"}, q ->
        case scope.user do
          %{login: login} -> where(q, [a], a.actor_login == ^login)
          _ -> q
        end

      _, q ->
        q
    end)
  end

  # A qualifier still being typed ("branch:") doesn't filter yet.
  defp search_term(term, q) when term in ["branch:", "actor:", "pr:", "#"], do: q

  defp search_term("branch:" <> branch, q), do: where(q, [a], a.head_branch == ^branch)

  defp search_term("actor:" <> actor, q),
    do: where(q, [a], fragment("lower(?) = lower(?)", a.actor_login, ^actor))

  defp search_term("pr:" <> pr, q), do: pr_term(pr, q)

  defp search_term("#" <> digits = term, q) do
    if digits =~ ~r/^\d+$/, do: pr_term(digits, q), else: text_term(term, q)
  end

  defp search_term(term, q) do
    case pr_number(term) do
      nil -> text_term(term, q)
      n -> where(q, ^dynamic([a], a.pr_number == ^n or ^text_match(term)))
    end
  end

  defp pr_term(pr, q) do
    case pr_number(pr) do
      nil -> where(q, false)
      n -> where(q, [a], a.pr_number == ^n)
    end
  end

  # A PR number is positive and fits the column, a 32-bit integer; a
  # bigger one would fail the query rather than match nothing.
  @max_pr 2_147_483_647
  defp pr_number(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..@max_pr -> n
      _ -> nil
    end
  end

  defp text_term(term, q), do: where(q, ^text_match(term))

  # lower() on both sides, so the database folds case the same way for
  # the column and the search (SQLite's lower() is ASCII only). "!" is
  # the escape: no string-literal backslash rules to depend on.
  defp text_match(term) do
    pattern = "%" <> String.replace(term, ["!", "%", "_"], &("!" <> &1)) <> "%"

    dynamic(
      [a],
      fragment("lower(?) LIKE lower(?) ESCAPE '!'", a.head_branch, ^pattern) or
        fragment("lower(?) LIKE lower(?) ESCAPE '!'", a.actor_login, ^pattern)
    )
  end

  defp with_earlier_attempts(%RunAttempt{} = attempt) do
    earlier =
      if attempt.run_attempt > 1 do
        Repo.all(
          from a in RunAttempt,
            where:
              a.github_run_id == ^attempt.github_run_id and a.run_attempt < ^attempt.run_attempt,
            order_by: [desc: a.run_attempt],
            select: a.run_attempt
        )
      else
        []
      end

    Map.put(attempt, :earlier_attempts, earlier)
  end

  @doc "A job of a run attempt the scope can read, by its GitHub id, with its attempt."
  def get_attempt_job!(%Crew.Scope{} = scope, run_id, attempt, job_github_id) do
    attempt = get_run_attempt!(scope, run_id, attempt)

    job =
      Enum.find(attempt.jobs, &(&1.github_id == job_github_id)) ||
        raise Ecto.NoResultsError, queryable: Job

    {attempt, job}
  end

  @doc """
  A running job's live steps from the API (§16.2), while someone has its
  page open: at most every 10 s per job, however many are watching. It's
  an optional call (§6.6).
  """
  def refresh_steps(%Job{gh_state: "in_progress"} = job) do
    with {:allow, _} <- Crew.RateLimit.hit("steps:#{job.id}", 9_000, 1),
         repo = job.repo_id |> Repos.get!() |> Repos.with_installation(),
         {:ok, data} <-
           Crew.GitHub.Client.get_job(repo.installation.github_id, repo.full_name, job.github_id,
             class: :optional
           ) do
      # Upserts only move a job forward, so steps of a job that's still
      # running are written on their own.
      if data["status"] == "in_progress",
        do: update_steps(job, data["steps"] || []),
        else: upsert_job(repo, data, source: "api", kind: "steps")
    end

    :ok
  end

  def refresh_steps(_job), do: :ok

  defp update_steps(job, steps) do
    {n, _} =
      Repo.update_all(from(j in Job, where: j.id == ^job.id and j.gh_state == "in_progress"),
        set: [steps: steps, updated_at: DateTime.utc_now()]
      )

    if n == 1, do: broadcast_job(job)
  end

  @doc "Every attempt of run `run_id` that `scope` may see, oldest first."
  def list_attempts(%Crew.Scope{} = scope, run_id) do
    from(a in RunAttempt, where: a.github_run_id == ^run_id, order_by: a.run_attempt)
    |> readable(scope)
    |> Repo.all()
  end

  @doc """
  A run attempt by GitHub run id and attempt number, if `scope` may see
  it. Raises `Ecto.NoResultsError` otherwise, so the page 404s.
  """
  def get_run_attempt!(%Crew.Scope{} = scope, run_id, attempt) do
    from(a in RunAttempt, where: a.github_run_id == ^run_id and a.run_attempt == ^attempt)
    |> readable(scope)
    |> preload([:repo, :jobs])
    |> Repo.one!()
    |> with_earlier_attempts()
  end

  # -- workflow_job ----------------------------------------------------------

  @doc "Applies a `workflow_job` webhook (or an API job, through `upsert_job/3`)."
  def handle_workflow_job(%{"workflow_job" => data} = payload) do
    with {:ok, repo} <- Repos.ensure_from_payload(payload) do
      upsert_job(repo, data, source: "webhook", kind: payload["action"] || data["status"])
    end
  end

  @doc """
  Upserts a job from GitHub's representation of it (the webhook's
  `workflow_job`, or the API's job). Returns the job as it is after.
  """
  def upsert_job(%GitRepo{} = repo, data, opts \\ []) do
    state = data["status"]

    if Job.state?(state) do
      do_upsert_job(repo, data, state, opts)
    else
      {:error, {:unknown_state, state}}
    end
  end

  defp do_upsert_job(repo, data, state, opts) do
    now = DateTime.utc_now()
    rank = Job.rank(state)
    github_id = data["id"]
    attempt = find_attempt(repo, data["run_id"], data["run_attempt"] || 1)
    labels = data["labels"] || []
    classified = Classify.classify(labels, context(repo, attempt))

    row =
      %{
        id: CrewProtocol.uuid7(),
        repo_id: repo.id,
        run_attempt_id: attempt && attempt.id,
        github_id: github_id,
        github_run_id: data["run_id"],
        run_attempt: data["run_attempt"] || 1,
        name: data["name"],
        workflow_name: data["workflow_name"],
        labels: labels,
        gh_state: state,
        gh_state_rank: rank,
        blocked_reason: blocked_reason(classified, attempt),
        seen_at: now,
        last_event_at: now,
        inserted_at: now,
        updated_at: now
      }
      |> Map.merge(
        Map.take(classified, [
          :classification,
          :unsatisfiable_reason,
          :label_key,
          :size_id,
          :arch,
          :aliased,
          :spare
        ])
      )
      |> Map.merge(progress(data))

    # Only the fields this event knows: a later event never blanks what an
    # earlier one set (a cancelled job's `completed` has no runner).
    set =
      [gh_state: state, gh_state_rank: rank, last_event_at: now, updated_at: now] ++
        (data |> progress() |> Enum.reject(fn {_, v} -> v in [nil, []] end))

    on_conflict = from(j in Job, where: j.gh_state_rank < ^rank, update: [set: ^set])

    {:ok, job} =
      Repo.transact(fn ->
        Repo.insert_all(Job, [row], on_conflict: on_conflict, conflict_target: [:github_id])
        job = Repo.get_by!(Job, github_id: github_id)

        record_event(
          job,
          opts[:source] || "webhook",
          opts[:kind] || state,
          event_payload(data),
          now
        )

        {:ok, job}
      end)

    after_upsert(repo, job, attempt)
    runner_named(job)

    if completed_now?(job, state, rank) do
      Crew.Jobs.FetchLog.schedule(job)
      summarize(job)
    end

    broadcast_job(job)
    {:ok, job}
  end

  defp progress(data) do
    %{
      conclusion: data["conclusion"],
      runner_name: data["runner_name"],
      queued_at: time(data["created_at"]),
      started_at: if(data["status"] in ~w(in_progress completed), do: time(data["started_at"])),
      completed_at: time(data["completed_at"]),
      steps: data["steps"] || []
    }
  end

  defp event_payload(data) do
    Map.take(data, ~w(status conclusion runner_name runner_id started_at completed_at))
  end

  # A Crew job whose run attempt isn't known waits for the fork check.
  defp after_upsert(repo, %Job{classification: "ours", run_attempt_id: nil} = job, nil) do
    %{repo_id: repo.id, run_id: job.github_run_id, attempt: job.run_attempt}
    |> FetchRunAttempt.new()
    |> Oban.insert()
  end

  # The run attempt came first (or with a sweep): a fork's Crew job is
  # refused now, which the attempt couldn't do with no jobs to look at.
  defp after_upsert(
         repo,
         %Job{unsatisfiable_reason: "fork PRs are refused on this repo"},
         %RunAttempt{} = attempt
       ),
       do: refuse_fork(repo, attempt)

  defp after_upsert(_repo, _job, _attempt), do: :ok

  @doc """
  Writes a job's final resource summary (§16.5), once its VM is gone and
  every sample is in: the one at completion can miss the last readings.
  Only a final summary has a `coverage`, which right-sizing needs before
  a run can argue for a smaller size.
  """
  def summarize_final(job_id) do
    case get_job(job_id) do
      %Job{} = job -> summarize(job)
      nil -> :ok
    end
  end

  # The resource summary (§16.5), from the VM's samples while the job ran.
  # It's written on the job's `completed`, or when the VM is linked after
  # that, and again once the VM is gone. Only then is every sample in, so
  # only then does it keep its coverage. It's display and hints only, so
  # failing to read it is logged and never fails the caller; the savepoint
  # keeps a failed query from spoiling a surrounding transaction.
  defp summarize(%Job{vm_id: vm_id} = job) when is_binary(vm_id) do
    Repo.transact(fn ->
      with %{} = vm <- Crew.VMs.get(vm_id),
           %{} = summary <- Crew.Metrics.job_summary(vm, job.started_at, job.completed_at) do
        summary = if vm.state == "destroyed", do: summary, else: %{summary | coverage: nil}
        Repo.update_all(from(j in Job, where: j.id == ^job.id), set: Map.to_list(summary))
      end

      {:ok, :done}
    end)

    :ok
  rescue
    e ->
      Logger.error("couldn't summarize job #{job.id}'s resources: #{Exception.message(e)}")
      :ok
  end

  defp summarize(_job), do: :ok

  # A Crew job's `completed` (the first one): GitHub's log is fetched.
  defp completed_now?(
         %Job{classification: "ours", gh_state: "completed", log_source: nil},
         "completed",
         _rank
       ),
       do: true

  defp completed_now?(_job, _state, _rank), do: false

  # GitHub named one of this deployment's runners: its VM is told (§8.6).
  defp runner_named(%Job{runner_name: name} = job) when is_binary(name) do
    if CrewProtocol.Names.ours?(name, Crew.Settings.deployment_id()),
      do: Crew.VMs.job_event(job, job.gh_state)
  end

  defp runner_named(_job), do: :ok

  defp blocked_reason(%{classification: "ours"}, nil), do: @checking_fork
  defp blocked_reason(%{classification: "ours"}, %RunAttempt{is_fork: nil}), do: @checking_fork
  defp blocked_reason(_classified, _attempt), do: nil

  defp record_event(job, source, kind, payload, at) do
    Repo.insert!(%JobEvent{
      job_id: job.id,
      source: source,
      kind: to_string(kind),
      payload: payload,
      at: at
    })
  end

  @doc "Records something that happened to a job (from the scheduler, the API or the guest)."
  def record_job_event(%Job{} = job, source, kind, payload \\ %{}) do
    record_event(job, source, kind, payload, DateTime.utc_now())
  end

  defp context(repo, attempt) do
    repo = Repo.preload(repo, :installation)

    %{
      repo: repo,
      sizes: Sizes.for_parse(),
      aliases: Sizes.aliases_for_parse(),
      missing_permissions: Repos.missing_permissions(repo.installation),
      fork: attempt && attempt.is_fork
    }
  end

  defp find_attempt(repo, run_id, attempt) do
    Repo.one(
      from a in RunAttempt,
        where: a.repo_id == ^repo.id and a.github_run_id == ^run_id and a.run_attempt == ^attempt
    )
  end

  # -- workflow_run ------------------------------------------------------------

  @doc "Applies a `workflow_run` webhook."
  def handle_workflow_run(%{"workflow_run" => run} = payload) do
    with {:ok, repo} <- Repos.ensure_from_payload(payload) do
      upsert_run_attempt(repo, run)
    end
  end

  @doc """
  Upserts a run attempt from GitHub's run (webhook or API), links its
  jobs, and settles their fork check (§19.5).
  """
  def upsert_run_attempt(%GitRepo{} = repo, run) do
    now = DateTime.utc_now()
    head_repo = get_in(run, ["head_repository", "full_name"])
    status = run["status"]
    rank = RunAttempt.rank(status)

    row = %{
      id: CrewProtocol.uuid7(),
      repo_id: repo.id,
      github_run_id: run["id"],
      run_attempt: run["run_attempt"] || 1,
      run_number: run["run_number"],
      workflow_name: run["name"],
      event: run["event"],
      head_branch: run["head_branch"],
      head_sha: run["head_sha"],
      head_commit_message: get_in(run, ["head_commit", "message"]),
      actor_login: get_in(run, ["actor", "login"]),
      actor_id: get_in(run, ["actor", "id"]),
      pull_requests: Enum.map(run["pull_requests"] || [], &pull_request/1),
      pr_number: get_in(run, ["pull_requests", Access.at(0), "number"]),
      head_repo_full_name: head_repo,
      is_fork: RunAttempt.fork?(run["event"], head_repo, repo.full_name),
      status: status,
      conclusion: run["conclusion"],
      gh_created_at: time(run["created_at"]),
      gh_updated_at: time(run["updated_at"]),
      inserted_at: now,
      updated_at: now
    }

    set = [
      status: status,
      conclusion: run["conclusion"],
      gh_updated_at: row.gh_updated_at,
      updated_at: now
    ]

    on_conflict =
      from(a in RunAttempt,
        where:
          fragment(
            "CASE ? WHEN 'completed' THEN 3 WHEN 'in_progress' THEN 2 WHEN 'requested' THEN 0 ELSE 1 END",
            a.status
          ) < ^rank,
        update: [set: ^set]
      )

    Repo.insert_all(RunAttempt, [row],
      on_conflict: on_conflict,
      conflict_target: [:github_run_id, :run_attempt]
    )

    attempt =
      Repo.one!(
        from a in RunAttempt,
          where: a.github_run_id == ^row.github_run_id and a.run_attempt == ^row.run_attempt
      )

    settle_attempt_jobs(repo, attempt)
    Phoenix.PubSub.broadcast(Crew.PubSub, "jobs", {:run_changed, attempt.id})
    Phoenix.PubSub.broadcast(Crew.PubSub, "run:#{attempt.id}", {:run_changed, attempt.id})
    Phoenix.PubSub.broadcast(Crew.PubSub, repo_topic(attempt.repo_id), {:run_changed, attempt.id})
    {:ok, attempt}
  end

  defp pull_request(pr) do
    %{
      "number" => pr["number"],
      "head_ref" => get_in(pr, ["head", "ref"]),
      "base_ref" => get_in(pr, ["base", "ref"])
    }
  end

  # Links the attempt's jobs and re-classifies the open ones, now that
  # the fork check has an answer.
  defp settle_attempt_jobs(repo, attempt) do
    Repo.update_all(
      from(j in Job,
        where:
          j.repo_id == ^repo.id and j.github_run_id == ^attempt.github_run_id and
            j.run_attempt == ^attempt.run_attempt and is_nil(j.run_attempt_id)
      ),
      set: [run_attempt_id: attempt.id]
    )

    attempt |> list_attempt_jobs() |> Enum.each(&reclassify(&1, repo, attempt))

    # Cancel only runs with jobs that asked for Crew: a fork's run of
    # GitHub-hosted jobs isn't Crew's to stop.
    if attempt.is_fork and repo.fork_prs == "refuse" and
         Enum.any?(list_attempt_jobs(attempt), &crew_label_job?/1) do
      refuse_fork(repo, attempt)
    end
  end

  defp crew_label_job?(%Job{unsatisfiable_reason: "fork PRs are refused on this repo"}), do: true
  defp crew_label_job?(_job), do: false

  defp refuse_fork(repo, attempt) do
    {:ok, oban_job} =
      %{repo_id: repo.id, run_id: attempt.github_run_id, attempt: attempt.run_attempt}
      |> CancelRun.new()
      |> Oban.insert()

    # Once per attempt: the cancel worker is unique, and so is the audit.
    unless oban_job.conflict? do
      Audit.log(nil, "run.fork_refused", attempt, %{
        "repo" => repo.full_name,
        "run_id" => attempt.github_run_id,
        "head_repo" => attempt.head_repo_full_name
      })

      Crew.Activity.record("fork_refused", "Refused a fork PR's run on #{repo.full_name}",
        repo_id: repo.id,
        masked: "Refused a fork PR's run in another repo"
      )
    end
  end

  # -- reclassifying ---------------------------------------------------------

  @doc """
  Re-parses the jobs GitHub still has queued or waiting (§7.4), for one
  repo or all of them, after a settings, size or alias change.
  """
  def reclassify_open(opts \\ []) do
    query = from j in Job, where: j.gh_state in ["waiting", "queued"]

    query =
      case opts[:repo_id] do
        nil -> query
        id -> where(query, [j], j.repo_id == ^id)
      end

    for job <- Repo.all(query) do
      repo = Repos.get!(job.repo_id)
      attempt = job.run_attempt_id && get_run_attempt(job.run_attempt_id)
      reclassify(job, repo, attempt)
    end

    :ok
  end

  defp reclassify(%Job{gh_state: state} = job, repo, attempt)
       when state in ["waiting", "queued"] do
    classified = Classify.classify(job.labels, context(repo, attempt))

    changes =
      classified
      |> Map.take([
        :classification,
        :unsatisfiable_reason,
        :label_key,
        :size_id,
        :arch,
        :aliased,
        :spare
      ])
      |> Map.put(:blocked_reason, fork_blocked(job, classified, attempt))

    changeset = Ecto.Changeset.change(job, changes)

    if changeset.changes != %{} do
      job = Repo.update!(changeset)
      broadcast_job(job)
    end
  end

  defp reclassify(_job, _repo, _attempt), do: :ok

  # Re-classifying only settles the fork check; the scheduler owns the
  # other blocked reasons and recomputes them every pass.
  defp fork_blocked(job, classified, attempt) do
    case {blocked_reason(classified, attempt), job.blocked_reason} do
      {@checking_fork, _} -> @checking_fork
      {nil, @checking_fork} -> nil
      {nil, other} -> if classified.classification == "ours", do: other
    end
  end

  # -- helpers -----------------------------------------------------------------

  @doc """
  Queue depth and booting VMs over the last `hours`, in 5-minute steps
  (the Queue page's chart): from jobs' `queued_at`/`started_at` and VMs'
  `requested_at`/`idle_at`, so nothing needs sampling. Times are Unix
  seconds.
  """
  def queue_series(now \\ DateTime.utc_now(), hours \\ 6) do
    since = DateTime.add(now, -hours * 3600)
    step = 300
    ticks = for t <- 0..div(hours * 3600, step), do: DateTime.to_unix(since) + t * step

    # A job was waiting from queued_at until it started, or until it
    # completed without starting (cancelled in the queue). Any job waiting
    # inside the window is still queued, started in it, or completed in it
    # without starting: three indexed reads instead of a scan.
    ours =
      from(j in Job,
        where: j.classification == "ours",
        select: {j.id, j.queued_at, [j.started_at, j.completed_at]}
      )

    jobs =
      [
        where(ours, [j], j.gh_state == "queued"),
        where(ours, [j], j.started_at > ^since),
        where(
          ours,
          [j],
          j.gh_state == "completed" and j.completed_at > ^since and is_nil(j.started_at)
        )
      ]
      |> Enum.flat_map(&Repo.all/1)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {_, from, ends} -> {from, ends} end)

    # Boots are cut off within minutes (§9.2), so an hour's margin before
    # the window catches every boot that overlaps it.
    vms =
      Repo.all(
        from v in Crew.VMs.VM,
          where: v.requested_at > ^DateTime.add(since, -3600),
          select: {v.requested_at, [v.idle_at, v.busy_at, v.failed_at, v.destroyed_at]}
      )

    %{
      since: DateTime.to_unix(since),
      until: DateTime.to_unix(now),
      depth: count_open(ticks, jobs),
      booting: count_open(ticks, vms)
    }
  end

  # How many {from, [ends]} intervals were open at each tick.
  defp count_open(ticks, intervals) do
    spans =
      for {from, ends} <- intervals, from do
        {DateTime.to_unix(from),
         ends
         |> Enum.reject(&is_nil/1)
         |> Enum.map(&DateTime.to_unix/1)
         |> Enum.min(fn -> nil end)}
      end

    for t <- ticks, do: {t, Enum.count(spans, fn {a, b} -> a <= t and (is_nil(b) or b > t) end)}
  end

  # -- the dashboard (§17.3) ----------------------------------------------------------

  @doc "Running, waiting (regular, with spare apart) and booting counts for Crew's jobs."
  def counts do
    running =
      Repo.aggregate(
        from(j in Job, where: j.classification == "ours" and j.gh_state == "in_progress"),
        :count
      )

    # Waiting is regular jobs; spare ones (§7.2) are counted apart.
    waiting =
      Repo.all(
        from j in Job,
          where: j.classification == "ours" and j.gh_state == "queued",
          group_by: j.spare,
          select: {j.spare, count(j.id)}
      )
      |> Map.new()

    booting =
      Repo.aggregate(
        from(v in Crew.VMs.VM, where: v.state in ["requested", "starting", "booted"]),
        :count
      )

    %{
      running: running,
      waiting: Map.get(waiting, false, 0),
      waiting_spare: Map.get(waiting, true, 0),
      booting: booting
    }
  end

  @doc "The `n` longest-waiting Crew jobs, with their reasons."
  def longest_waiting(n \\ 10) do
    # Regular jobs first: spare ones (§7.2) can wait for hours by design.
    Repo.all(
      from j in Job,
        where: j.classification == "ours" and j.gh_state == "queued",
        order_by: [asc: j.spare, asc: coalesce(j.queued_at, j.seen_at)],
        limit: ^n,
        preload: [:repo, :size]
    )
  end

  @doc "The `n` Crew jobs completed last."
  def recently_completed(n \\ 20) do
    Repo.all(
      from j in Job,
        where: j.classification == "ours" and j.gh_state == "completed",
        order_by: [desc: j.completed_at],
        limit: ^n,
        preload: [:repo, :size]
    )
  end

  @doc """
  Crew jobs started per 5 minutes over the last day, by conclusion (the
  dashboard's stacked chart). Times are Unix seconds.
  """
  def started_series(now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -86_400)
    step = 300

    rows =
      Repo.all(
        from j in Job,
          where: j.classification == "ours" and j.started_at > ^since,
          select: {j.started_at, j.conclusion}
      )

    bucket = fn at -> div(DateTime.to_unix(at), step) * step end

    ticks =
      for i <- 0..div(86_400, step), do: div(DateTime.to_unix(since), step) * step + i * step

    by = fn pick ->
      counts =
        rows
        |> Enum.filter(fn {_, c} -> pick.(c) end)
        |> Enum.frequencies_by(fn {at, _} -> bucket.(at) end)

      for t <- ticks, do: {t, Map.get(counts, t, 0)}
    end

    %{
      since: DateTime.to_unix(since),
      until: DateTime.to_unix(now),
      success: by.(&(&1 == "success")),
      failure: by.(&(&1 == "failure")),
      other: by.(&(&1 not in ["success", "failure"]))
    }
  end

  @doc """
  p50 and p95 of the wait (seen → placed) and the boot (placed → runner
  listening) per hour over the last day, from VMs and their jobs (§16.4).
  """
  def phase_series(now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -86_400)

    rows =
      Repo.all(
        from v in Crew.VMs.VM,
          join: j in Job,
          on: j.id == v.job_id,
          where: v.requested_at > ^since,
          select: {v.requested_at, j.seen_at, v.idle_at}
      )

    hour = fn at -> div(DateTime.to_unix(at), 3600) * 3600 end

    series = fn values ->
      values
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort()
      |> Enum.map(fn {t, xs} ->
        {t, Insights.percentile(xs, 0.5), Insights.percentile(xs, 0.95)}
      end)
    end

    waits =
      for {placed, seen, _} <- rows,
          seen,
          do: {hour.(placed), max(DateTime.diff(placed, seen), 0)}

    boots =
      for {placed, _, idle} <- rows,
          idle,
          do: {hour.(placed), max(DateTime.diff(idle, placed), 0)}

    %{
      since: DateTime.to_unix(since),
      until: DateTime.to_unix(now),
      wait: series.(waits),
      boot: series.(boots)
    }
  end

  @doc "The last `n` successful completions of the same job (repo, workflow, name), for \"usually X\"."
  def recent_successes(%Job{} = job, n) do
    Repo.all(
      from j in Job,
        where:
          j.repo_id == ^job.repo_id and j.workflow_name == ^job.workflow_name and
            j.name == ^job.name and
            j.conclusion == "success" and j.id != ^job.id,
        order_by: [desc: j.completed_at],
        limit: ^n,
        select: map(j, [:steps])
    )
  end

  @doc """
  A person's Cancel run, Re-run failed jobs or Re-run all (§17.3): they
  need `can_push` on the repo (§18.3), are made with the installation's
  token, and are audited with the person.
  """
  def run_action(%Crew.Scope{} = scope, %RunAttempt{} = attempt, action)
      when action in [:cancel, :rerun, :rerun_failed] do
    if Repos.can_push?(scope, attempt.repo_id) do
      repo = attempt.repo_id |> Repos.get!() |> Repos.with_installation()
      inst = repo.installation.github_id

      result =
        case action do
          :cancel ->
            Crew.GitHub.Client.cancel_run(inst, repo.full_name, attempt.github_run_id)

          :rerun ->
            Crew.GitHub.Client.rerun(inst, repo.full_name, attempt.github_run_id)

          :rerun_failed ->
            Crew.GitHub.Client.rerun_failed(inst, repo.full_name, attempt.github_run_id)
        end

      case result do
        :ok ->
          Audit.log(scope, "run.#{action}", attempt, %{
            "run_id" => attempt.github_run_id,
            "attempt" => attempt.run_attempt
          })

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc "Where the job page's log comes from: `github` once GitHub's is stored, else `live`."
  def set_log_source(%Job{} = job, source) when source in ["github", "live"] do
    job = job |> Ecto.Changeset.change(log_source: source) |> Repo.update!()
    broadcast_job(job)
    {:ok, job}
  end

  @doc "Broadcasts that a job changed (another context wrote it)."
  def changed(job_id) do
    with %Job{} = job <- get_job(job_id), do: broadcast_job(job)
    :ok
  end

  @doc "Subscribes to one repo's job and run changes (§9.3): `{:job_changed, id}` and `{:run_changed, id}`."
  def subscribe_repo(repo_id), do: Phoenix.PubSub.subscribe(Crew.PubSub, repo_topic(repo_id))

  defp repo_topic(repo_id), do: "repo:#{repo_id}"

  defp broadcast_job(job) do
    Phoenix.PubSub.broadcast(Crew.PubSub, "jobs", {:job_changed, job.id})
    Phoenix.PubSub.broadcast(Crew.PubSub, "job:#{job.id}", {:job_changed, job.id})
    Phoenix.PubSub.broadcast(Crew.PubSub, repo_topic(job.repo_id), {:job_changed, job.id})

    if job.run_attempt_id,
      do:
        Phoenix.PubSub.broadcast(Crew.PubSub, "run:#{job.run_attempt_id}", {:job_changed, job.id})
  end

  defp time(nil), do: nil

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        DateTime.add(dt, 0, :microsecond)
        |> then(&%{&1 | microsecond: {elem(&1.microsecond, 0), 6}})

      _ ->
        nil
    end
  end
end
