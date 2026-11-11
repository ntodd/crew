defmodule Crew.Schedules do
  @moduledoc """
  Workflows Crew starts on a cron (§7.6).

  GitHub runs a workflow's own `schedule:` trigger when it gets to it,
  which can be hours late. A schedule here fires a `workflow_dispatch`
  in the right minute instead, through the App's `actions: write`.

  Each schedule keeps a clock, `last_due_at`: the latest cron minute
  accounted for. `due/1` lists the schedules whose cron has matched
  since their clock, within the last hour: a tick missed while the
  control plane was down fires once, late, but a match older than that
  (a schedule disabled for a week, a long outage) waits for the next
  one rather than running a night job in the afternoon. `fire/2` moves
  the clock first, in one statement, so two ticks for the same minute
  dispatch once; it moves whether or not GitHub took the dispatch, so a
  broken schedule fails once per match, not once per minute, and shows
  its last error on the repo page.
  """
  import Ecto.Query

  require Logger

  alias Crew.{Audit, Repo, Scope}
  alias Crew.GitHub.Client
  alias Crew.Repos.Repo, as: GitRepo
  alias Crew.Schedules.Schedule
  alias Oban.Cron.Expression

  @error_max 500
  # How late a missed match may still fire (§7.6).
  @catch_up_s 3600

  def subscribe(repo_id), do: Phoenix.PubSub.subscribe(Crew.PubSub, topic(repo_id))

  defp topic(repo_id), do: "schedules:#{repo_id}"

  defp broadcast(repo_id),
    do: Phoenix.PubSub.broadcast(Crew.PubSub, topic(repo_id), {:schedules_changed, repo_id})

  @doc "A repo's schedules, oldest first."
  def list(repo_id),
    do: Repo.all(from s in Schedule, where: s.repo_id == ^repo_id, order_by: s.inserted_at)

  def change(%Schedule{} = schedule, attrs \\ %{}), do: Schedule.changeset(schedule, attrs)

  @doc "Adds a schedule to a repo (admins). Its clock starts now: the first fire is the next match."
  def create(%Scope{} = scope, %GitRepo{} = repo, attrs) do
    authorize(scope, fn ->
      %Schedule{repo_id: repo.id, last_due_at: DateTime.utc_now()}
      |> Schedule.changeset(attrs)
      |> Repo.insert()
      |> changed(scope, "schedule.create")
    end)
  end

  @doc """
  Changes a schedule (admins). Enabling it, or giving it a new cron,
  restarts its clock: the matches missed while it was off, or under
  the old cron, aren't owed.
  """
  def update(%Scope{} = scope, %Schedule{} = schedule, attrs) do
    authorize(scope, fn ->
      schedule
      |> Schedule.changeset(attrs)
      |> restart_clock()
      |> Repo.update()
      |> changed(scope, "schedule.update")
    end)
  end

  defp restart_clock(changeset) do
    if Ecto.Changeset.get_change(changeset, :enabled) == true or
         Ecto.Changeset.get_change(changeset, :cron) != nil,
       do: Ecto.Changeset.put_change(changeset, :last_due_at, DateTime.utc_now()),
       else: changeset
  end

  def delete(%Scope{} = scope, %Schedule{} = schedule) do
    authorize(scope, fn -> schedule |> Repo.delete() |> changed(scope, "schedule.delete") end)
  end

  @doc """
  Starts the schedule's workflow right away (admins). The schedule's own
  clock doesn't move: it still fires at its next match.
  """
  def run_now(%Scope{} = scope, %Schedule{} = schedule) do
    authorize(scope, fn ->
      schedule = Repo.preload(schedule, repo: :installation)
      now = DateTime.utc_now()

      case dispatch(schedule) do
        :ok ->
          Audit.log(scope, "schedule.run", schedule, describe(schedule))
          {:ok, save(schedule, last_dispatched_at: now, last_error: nil)}

        {:error, reason} ->
          error = error_text(reason)
          Audit.log(scope, "schedule.run", schedule, Map.put(describe(schedule), "error", error))
          {:error, save(schedule, last_error: error)}
      end
    end)
  end

  # -- firing (Crew.Schedules.Tick) --------------------------------------------

  @doc """
  The enabled schedules of live repos whose cron has matched since their
  clock, within the last hour, with the repo and its installation.
  """
  def due(now \\ DateTime.utc_now()) do
    Repo.all(
      from s in Schedule,
        join: r in assoc(s, :repo),
        where: s.enabled and r.enabled and is_nil(r.archived_at),
        order_by: s.inserted_at,
        preload: [repo: {r, :installation}]
    )
    |> Enum.filter(&due?(&1, now))
  end

  defp due?(%Schedule{} = schedule, now) do
    match = latest_match(schedule, now)

    DateTime.compare(match, schedule.last_due_at) == :gt and
      DateTime.diff(now, match) <= @catch_up_s
  end

  @doc """
  Starts the schedule's workflow for its latest match. The clock moves
  to that match first, in one statement: a second tick for the same
  minute finds it moved and does nothing (`:already_fired`). GitHub's
  answer is kept when the dispatch fails.
  """
  def fire(%Schedule{} = schedule, now \\ DateTime.utc_now()) do
    schedule = Repo.preload(schedule, repo: :installation)
    clock = latest_match(schedule, now)

    with :claimed <- claim(schedule, clock) do
      schedule = %{schedule | last_due_at: clock}

      case dispatch(schedule) do
        :ok ->
          {:ok, save(schedule, last_dispatched_at: now, last_error: nil)}

        {:error, reason} ->
          error = error_text(reason)

          Logger.warning(
            "schedule: #{schedule.repo.full_name} #{schedule.workflow} on #{schedule.ref}: #{error}"
          )

          {:error, save(schedule, last_error: error)}
      end
    end
  end

  defp claim(%Schedule{id: id}, clock) do
    query = from s in Schedule, where: s.id == ^id and s.last_due_at < ^clock

    case Repo.update_all(query, set: [last_due_at: clock, updated_at: DateTime.utc_now()]) do
      {1, _} -> :claimed
      {0, _} -> :already_fired
    end
  end

  @doc "The next minute the schedule's cron matches, after `now`."
  def next_at(%Schedule{} = schedule, now \\ DateTime.utc_now()),
    do: Expression.next_at(Schedule.expression!(schedule), now)

  # The most recent cron minute at or before `now`. Oban's `last_at/2`
  # looks strictly before the minute it's given, so it gets the next one.
  defp latest_match(%Schedule{} = schedule, now) do
    schedule
    |> Schedule.expression!()
    |> Expression.last_at(DateTime.add(now, 1, :minute))
    |> Map.put(:microsecond, {0, 6})
  end

  # A crash in the client (a lost connection, a budget call that timed
  # out) is an error like any other: recorded, and the next schedule runs.
  defp dispatch(%Schedule{repo: %GitRepo{installation: installation} = repo} = schedule) do
    Client.dispatch_workflow(
      installation.github_id,
      repo.full_name,
      schedule.workflow,
      schedule.ref
    )
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp save(%Schedule{} = schedule, fields) do
    saved = schedule |> Ecto.Changeset.change(fields) |> Repo.update!()
    broadcast(saved.repo_id)
    saved
  end

  # -- helpers ------------------------------------------------------------------

  defp authorize(scope, fun),
    do: if(Scope.admin?(scope), do: fun.(), else: {:error, :unauthorized})

  defp changed({:ok, %Schedule{} = schedule} = ok, scope, action) do
    Audit.log(scope, action, schedule, describe(schedule))
    broadcast(schedule.repo_id)
    ok
  end

  defp changed(error, _scope, _action), do: error

  defp describe(%Schedule{} = s),
    do: %{"workflow" => s.workflow, "ref" => s.ref, "cron" => s.cron, "enabled" => s.enabled}

  defp error_text({:http, status, nil}), do: "HTTP #{status}"
  defp error_text({:http, status, message}), do: clip("HTTP #{status}: #{message}")
  defp error_text({:delayed, at}), do: "GitHub API budget low, waiting until #{at_text(at)}"
  defp error_text({:backoff, at}), do: "backing off from GitHub's API until #{at_text(at)}"
  defp error_text({:write_limited, at}), do: "at GitHub's write limit until #{at_text(at)}"
  defp error_text(:busy), do: "GitHub's API budget was busy"
  defp error_text({:exit, reason}), do: clip("crashed: #{inspect(reason)}")
  defp error_text(%{__exception__: true} = e), do: clip("crashed: #{Exception.message(e)}")
  defp error_text(other), do: clip(inspect(other))

  defp at_text(unix_ms) when is_integer(unix_ms),
    do:
      unix_ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  defp clip(text), do: String.slice(text, 0, @error_max)
end
