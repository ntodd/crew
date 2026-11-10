defmodule CrewWeb.RepoLive.Show do
  @moduledoc """
  A repo (§17.3), full width: its CI over the last 7 or 30 days (the
  window is in the URL) from `Crew.Jobs.Insights`, with a stats strip,
  jobs per day and run time charts, every workflow's jobs, the flaky
  ones, recent runs, right-sizing hints (§7.5) and VM time (§16.6); then
  a rail with its settings (§7.4, admins), schedules (§7.6, admins) and
  `runs-on` snippets with a line on `-spare` (§7.2), and the permissions
  its installation is missing.
  Changing settings re-parses its queued jobs. Jobs finishing refresh
  the numbers, a few seconds at a time.
  """
  use CrewWeb, :live_view

  alias Crew.{Jobs, Repos, Schedules, Scope, Sizes, Sizing, Usage}
  alias Crew.Jobs.Insights
  alias Crew.Schedules.Schedule

  alias CrewWeb.{
    Charts,
    GitHub,
    JobStatus,
    SizingActions,
    SizingComponents,
    SizingIssue,
    UsageComponents
  }

  alias CrewWeb.Charts.Geometry

  import CrewWeb.UsageComponents, only: [minutes: 1, delimit: 1, pct: 1]

  @windows [7, 30]
  @default_window 30
  @recent_runs 8
  @flush_ms 5_000

  @sizing_events SizingActions.events()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    repo = Repos.get(id)

    unless repo && Repos.can_read?(scope, repo.id),
      do: raise(Ecto.NoResultsError, queryable: Crew.Repos.Repo)

    if connected?(socket) do
      Jobs.subscribe_repo(repo.id)
      if Scope.admin?(scope), do: Schedules.subscribe(repo.id)
    end

    {:ok,
     socket
     |> assign(:page_title, repo.full_name)
     |> assign(:sizes, Sizes.list())
     |> assign(:windows, @windows)
     |> assign(:flush_pending, false)
     |> SizingActions.mount()
     |> assign_repo(repo)
     |> assign_schedules()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    days =
      case Integer.parse(params["days"] || "") do
        {d, ""} when d in @windows -> d
        _ -> @default_window
      end

    {:noreply, socket |> assign(:days, days) |> load()}
  end

  # What the window governs: the insights, recent runs and VM time. A
  # member whose access lapsed while the page was open (§18.3) is sent
  # back to the list rather than shown a page with nothing in it.
  defp load(socket) do
    %{current_scope: scope, repo: repo, days: days} = socket.assigns
    today = Date.utc_today()

    case Insights.for_repo(scope, repo, days, today) do
      nil ->
        socket
        |> put_flash(:error, "You no longer have access to #{repo.full_name}.")
        |> push_navigate(to: ~p"/repos")

      insights ->
        socket
        |> assign(:now, DateTime.utc_now())
        |> assign(:insights, insights)
        |> assign(:runs, Jobs.list_runs(scope, %{"repo_id" => repo.id}, limit: @recent_runs))
        |> assign(
          :usage,
          Usage.summary(scope, Date.add(today, 1 - days), today, repo_id: repo.id)
        )
    end
  end

  defp assign_repo(socket, repo) do
    repo = Repos.with_installation(repo)

    socket
    |> assign(:repo, repo)
    |> assign_hints(repo)
    |> assign(:missing, Repos.missing_permissions(repo.installation))
    |> assign(:form, to_form(Repos.change_settings(repo), as: :repo))
  end

  # The repo's hints, each with its issue, and one issue for them all.
  defp assign_hints(socket, repo) do
    crew = Crew.Config.base_url()

    {dismissed, hints} =
      socket.assigns.current_scope
      |> Sizing.for_repo(repo)
      |> Enum.map(&Map.put(&1, :repo, repo))
      |> Enum.split_with(& &1.dismissal)

    hints = SizingIssue.put_issues(hints, crew)

    assign(socket,
      hints: hints,
      dismissed_hints: dismissed,
      repo_issue: SizingIssue.for_repo(repo, hints, crew)
    )
  end

  # Admins only (§7.6): the panel isn't rendered for members, so nothing is loaded.
  defp assign_schedules(socket) do
    %{current_scope: scope, repo: repo} = socket.assigns

    if Scope.admin?(scope) do
      socket
      |> assign(:schedules, Schedules.list(repo.id))
      |> assign(
        :schedule_form,
        schedule_form(Schedules.change(%Schedule{ref: repo.default_branch}))
      )
    else
      socket |> assign(:schedules, []) |> assign(:schedule_form, nil)
    end
  end

  defp schedule_form(changeset), do: to_form(changeset, as: :schedule)

  @impl true
  def handle_event(event, params, socket) when event in @sizing_events,
    do:
      SizingActions.handle(event, params, socket, fn socket ->
        assign_hints(socket, socket.assigns.repo)
      end)

  def handle_event("save", %{"repo" => params}, socket) do
    params =
      Map.update(params, "allowed_sizes", [], &Enum.reject(List.wrap(&1), fn v -> v == "" end))

    case Repos.update_settings(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, repo} ->
        Jobs.reclassify_open(repo_id: repo.id)
        {:noreply, socket |> assign_repo(repo) |> put_flash(:info, "Saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :repo, action: :update))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins change repo settings.")}
    end
  end

  def handle_event("create_schedule", %{"schedule" => params}, socket) do
    case Schedules.create(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, _schedule} ->
        {:noreply, socket |> assign_schedules() |> put_flash(:info, "Schedule added.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :schedule_form, schedule_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins change schedules.")}
    end
  end

  def handle_event("run_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      case Schedules.run_now(socket.assigns.current_scope, schedule) do
        {:ok, s} ->
          put_flash(socket, :info, "Started #{s.workflow} on #{s.ref}.")

        {:error, %Schedule{last_error: error}} ->
          put_flash(socket, :error, "GitHub refused: #{error}")

        {:error, :unauthorized} ->
          put_flash(socket, :error, "Only admins run schedules.")
      end
    end)
  end

  def handle_event("toggle_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      scope = socket.assigns.current_scope

      case Schedules.update(scope, schedule, %{"enabled" => !schedule.enabled}) do
        {:ok, _} -> socket
        {:error, _} -> put_flash(socket, :error, "Only admins change schedules.")
      end
    end)
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      case Schedules.delete(socket.assigns.current_scope, schedule) do
        {:ok, _} -> put_flash(socket, :info, "Schedule removed.")
        {:error, _} -> put_flash(socket, :error, "Only admins change schedules.")
      end
    end)
  end

  # Acts on one of this repo's schedules, as listed: an id from elsewhere does nothing.
  defp with_schedule(socket, id, fun) do
    case Enum.find(socket.assigns.schedules, &(&1.id == id)) do
      %Schedule{} = schedule -> {:noreply, schedule |> fun.() |> assign_schedules()}
      nil -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:schedules_changed, _repo_id}, socket),
    do: {:noreply, assign_schedules(socket)}

  # Jobs change often while a run is going; the page reloads at most every few seconds.
  def handle_info({event, _id}, socket) when event in [:job_changed, :run_changed] do
    if socket.assigns.flush_pending do
      {:noreply, socket}
    else
      Process.send_after(self(), :flush, @flush_ms)
      {:noreply, assign(socket, :flush_pending, true)}
    end
  end

  def handle_info(:flush, socket),
    do: {:noreply, socket |> assign(:flush_pending, false) |> load()}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The -spare examples (§7.2) that would run here: crew-spare when the
  # default size is allowed, and the largest allowed size's. A size named
  # before the rule (`spare`, `l-spare`) keeps the label it hides.
  defp spare_examples(allowed, sizes) do
    names = MapSet.new(sizes, & &1.name)
    hidden? = &MapSet.member?(names, &1)

    default =
      if Enum.any?(allowed, & &1.is_default) and not hidden?.("spare"),
        do: ["crew-spare"],
        else: []

    sized =
      allowed
      |> Enum.map(&"#{&1.name}-spare")
      |> Enum.reject(hidden?)
      |> List.last()
      |> List.wrap()
      |> Enum.map(&("crew-" <> &1))

    default ++ sized
  end

  defp allowed(repo, sizes) do
    sizes
    |> Enum.reject(&(&1.retired_at != nil))
    |> Enum.filter(&(repo.allowed_sizes == nil or &1.name in repo.allowed_sizes))
  end

  defp window_path(repo, @default_window), do: ~p"/repos/#{repo.id}"
  defp window_path(repo, days), do: ~p"/repos/#{repo.id}?days=#{days}"

  # A DOM id for a `(workflow, name)` row. Names take any characters, so
  # the id is a hash of them rather than a slug two names could share.
  defp dom_id(prefix, workflow, name), do: "#{prefix}-#{:erlang.phash2({workflow, name})}"

  defp job_title(workflow, name),
    do: Enum.map_join(Enum.reject([workflow, name], &is_nil/1), " · ", &to_string/1)

  defp job_path(%{github_run_id: run, run_attempt: attempt, github_id: id}),
    do: ~p"/runs/#{run}/attempts/#{attempt}/jobs/#{id}"

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{delimit(n)} #{word}s"

  defp pr_number(%{pull_requests: [%{"number" => n} | _]}), do: n
  defp pr_number(_run), do: nil

  defp run_duration(%{status: "completed", gh_created_at: from, gh_updated_at: to}, _now),
    do: JobStatus.duration(from, to)

  defp run_duration(%{gh_created_at: from}, now), do: JobStatus.duration(from, now)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
      <:breadcrumb navigate={~p"/repos"}>Repos</:breadcrumb>
      <:breadcrumb>{@repo.full_name}</:breadcrumb>

      <.header>
        {@repo.full_name}
        <:subtitle>
          {if @repo.private, do: "Private", else: "Public"} · default branch
          <span class="font-mono text-ink-2">{@repo.default_branch}</span>
          · installed on {@repo.installation.account_login}
        </:subtitle>
        <:actions>
          <div
            role="group"
            aria-label="Window"
            class="inline-flex rounded-lg border border-line bg-raised p-0.5 text-xs font-medium shadow-xs"
          >
            <.link
              :for={d <- @windows}
              id={"window-#{d}"}
              patch={window_path(@repo, d)}
              aria-current={@days == d && "page"}
              class={[
                "rounded-md px-2.5 py-1 tabular-nums transition-colors",
                if(@days == d,
                  do: "bg-subtle text-ink",
                  else: "text-ink-3 hover:text-ink"
                )
              ]}
            >
              {d} days
            </.link>
          </div>
          <.button
            size="sm"
            variant="secondary"
            icon="hero-play"
            navigate={~p"/runs?#{%{repo: @repo.full_name}}"}
          >
            Runs
          </.button>
          <.button
            size="sm"
            variant="ghost"
            icon="hero-arrow-top-right-on-square"
            href={GitHub.repo_url(@repo)}
            target="_blank"
            rel="noreferrer"
          >
            GitHub
          </.button>
        </:actions>
      </.header>

      <.callout
        :if={@missing != []}
        id="missing-permissions"
        kind="warning"
        icon="hero-exclamation-triangle"
      >
        The installation is missing permissions Crew needs, so its jobs can't run: {Enum.map_join(
          @missing,
          ", ",
          fn {p, l} -> "#{p} (#{l})" end
        )}. Accept the new permissions on GitHub.
      </.callout>

      <.stats :if={@insights.totals.jobs > 0} totals={@insights.totals} />

      <.panel :if={@insights.totals.jobs == 0} id="insights-empty" title="No Crew jobs yet">
        <p class="max-w-prose text-sm text-ink-2">
          Nothing from this repo ran on Crew in the last {@days} days. A job takes a Crew runner
          with one of the <code class="font-mono text-ink">runs-on</code>
          lines on the right; its numbers show up here once it finishes.
        </p>
      </.panel>

      <div class="mt-4 grid gap-4 xl:grid-cols-[minmax(0,1fr)_22rem]">
        <div class="min-w-0 space-y-4">
          <div :if={@insights.totals.jobs > 0} class="grid gap-4 lg:grid-cols-2">
            <.jobs_chart id="jobs-chart" insights={@insights} />
            <.run_time_chart id="run-time-chart" insights={@insights} />
          </div>

          <.panel :if={@insights.jobs != []} id="jobs" title="Workflows and jobs" padded={false}>
            <:subtitle>Every job that ran on Crew in the window, the most minutes first.</:subtitle>
            <div class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead class="text-left text-xs text-ink-3">
                  <tr>
                    <th class="px-5 py-2 font-medium">Job</th>
                    <th class="px-2 py-2 text-right font-medium">Runs</th>
                    <th class="px-2 py-2 font-medium">Pass rate</th>
                    <th class="px-2 py-2 text-right font-medium">p50</th>
                    <th class="px-2 py-2 text-right font-medium">p95</th>
                    <th class="hidden px-2 py-2 text-right font-medium md:table-cell">Wait p50</th>
                    <th class="px-2 py-2 text-right font-medium">Minutes</th>
                    <th class="px-5 py-2 text-right font-medium">Last run</th>
                  </tr>
                </thead>
                <tbody id="job-rows" class="divide-y divide-line">
                  <tr :for={j <- @insights.jobs} id={dom_id("job", j.workflow_name, j.name)}>
                    <td class="w-full min-w-[12rem] max-w-0 truncate px-5 py-2.5 font-medium text-ink">
                      <span :if={j.workflow_name} class="text-ink-2">{j.workflow_name} · </span>{j.name}
                    </td>
                    <td class="px-2 py-2.5 text-right tabular-nums text-ink-2">{delimit(j.runs)}</td>
                    <td class="px-2 py-2.5">
                      <.pass_rate rate={j.pass_rate} />
                    </td>
                    <td class="whitespace-nowrap px-2 py-2.5 text-right tabular-nums text-ink-2">
                      {JobStatus.format(j.run_p50)}
                    </td>
                    <td class="whitespace-nowrap px-2 py-2.5 text-right tabular-nums text-ink-2">
                      {JobStatus.format(j.run_p95)}
                    </td>
                    <td class="hidden whitespace-nowrap px-2 py-2.5 text-right tabular-nums text-ink-3 md:table-cell">
                      {JobStatus.format(j.wait_p50)}
                    </td>
                    <td class="px-2 py-2.5 text-right tabular-nums text-ink-2">{minutes(j.job_s)}</td>
                    <td class="whitespace-nowrap px-5 py-2.5 text-right text-xs">
                      <.link
                        navigate={job_path(j.last)}
                        class="inline-flex items-center gap-1.5 tabular-nums text-ink-2 underline-offset-2 hover:text-ink hover:underline"
                      >
                        <.run_status_icon
                          run={%{status: "completed", conclusion: j.last.conclusion}}
                          class="size-3.5"
                        />
                        {JobStatus.ago(j.last.completed_at, @now)} ago
                      </.link>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.panel>

          <.panel :if={@insights.totals.jobs > 0} id="flaky-jobs" title="Flaky jobs" padded={false}>
            <:subtitle>Failed, then passed on a re-run of the same commit.</:subtitle>
            <p :if={@insights.flaky == []} id="flaky-none" class="px-5 py-4 text-sm text-ink-3">
              None in the last {@days} days.
            </p>
            <ul :if={@insights.flaky != []} class="divide-y divide-line text-sm">
              <li
                :for={f <- @insights.flaky}
                id={dom_id("flaky", f.workflow_name, f.name)}
                class="flex flex-col gap-1 px-5 py-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-4"
              >
                <span class="flex min-w-0 items-center gap-2">
                  <.icon name="hero-arrow-path-micro" class="size-4 shrink-0 text-warning" />
                  <span class="truncate font-medium text-ink">{job_title(f.workflow_name, f.name)}</span>
                </span>
                <.link
                  navigate={job_path(f.last)}
                  class="shrink-0 pl-6 text-xs tabular-nums text-ink-2 underline-offset-2 hover:text-ink hover:underline sm:pl-0"
                >
                  {plural(f.flakes, "flake")} in {plural(f.runs, "run")} · last {JobStatus.ago(
                    f.last.completed_at,
                    @now
                  )} ago
                </.link>
              </li>
            </ul>
          </.panel>

          <.panel
            :if={@insights.totals.jobs > 0}
            id="cache-misses"
            title="Cache misses"
            padded={false}
          >
            <:subtitle>
              Dependency steps that took about as long on each of a job's last successful runs, so their cache likely never hits.
            </:subtitle>
            <p
              :if={@insights.cache_misses == []}
              id="cache-misses-none"
              class="px-5 py-4 text-sm text-ink-3"
            >
              None in the last {@days} days.
            </p>
            <ul :if={@insights.cache_misses != []} class="divide-y divide-line text-sm">
              <li
                :for={m <- @insights.cache_misses}
                id={dom_id("cache-miss", m.workflow_name, {m.name, m.step, m.number})}
                class="flex flex-col gap-1 px-5 py-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-4"
              >
                <span class="flex min-w-0 items-center gap-2">
                  <.icon name="hero-arrow-down-tray-micro" class="size-4 shrink-0 text-warning" />
                  <span class="min-w-0 truncate">
                    <span class="font-medium text-ink">{job_title(m.workflow_name, m.name)}</span>
                    <span class="text-ink-3"> · </span>
                    <span class="font-mono text-xs text-ink-2">{m.step}</span>
                  </span>
                </span>
                <.link
                  navigate={job_path(m.last) <> "#step-#{m.number}"}
                  title={"Fastest #{JobStatus.format(m.fastest)}"}
                  class="shrink-0 pl-6 text-xs tabular-nums text-ink-2 underline-offset-2 hover:text-ink hover:underline sm:pl-0"
                >
                  about {JobStatus.format(m.p50)} on each of {plural(m.runs, "run")}
                </.link>
              </li>
            </ul>
          </.panel>

          <.panel id="recent-runs" title="Recent runs" padded={false}>
            <:actions>
              <.link
                navigate={~p"/runs?#{%{repo: @repo.full_name}}"}
                class="text-xs font-medium text-accent-ink hover:underline"
              >
                All runs
              </.link>
            </:actions>
            <p :if={@runs == []} id="recent-runs-empty" class="px-5 py-4 text-sm text-ink-3">
              No runs seen yet. Crew hears about a run when GitHub queues it.
            </p>
            <ul :if={@runs != []} class="divide-y divide-line text-sm">
              <li
                :for={run <- @runs}
                id={"recent-run-#{run.id}"}
                class="grid grid-cols-[minmax(0,1fr)_4rem_4.5rem] items-center gap-x-4 px-5 py-2.5 sm:grid-cols-[minmax(0,1fr)_5rem_4rem_4.5rem]"
              >
                <div class="min-w-0">
                  <.link
                    navigate={~p"/runs/#{run.github_run_id}/attempts/#{run.run_attempt}"}
                    class="flex min-w-0 items-center gap-2 font-medium text-ink hover:underline"
                  >
                    <.run_status_icon run={run} />
                    <span class="truncate">{run.workflow_name}</span>
                    <span class="shrink-0 font-normal text-ink-3">#{run.run_number}</span>
                  </.link>
                  <p class="mt-0.5 truncate pl-6 text-xs text-ink-3">
                    <%= case {pr_number(run), run.head_branch} do %>
                      <% {nil, nil} -> %>
                        <span>{run.event || "run"}</span>
                      <% {nil, branch} -> %>
                        <.gh_link href={GitHub.branch_url(@repo, branch)}>{branch}</.gh_link>
                      <% {n, _} -> %>
                        <.gh_link href={GitHub.pr_url(@repo, n)}>PR #{n}</.gh_link>
                    <% end %>
                    <span :if={run.actor_login}> · {run.actor_login}</span>
                  </p>
                </div>
                <span class="hidden whitespace-nowrap text-right text-xs tabular-nums text-ink-3 sm:inline">
                  {plural(length(run.jobs), "job")}
                </span>
                <span title="Duration" class="text-right text-xs tabular-nums text-ink-2">
                  {JobStatus.format(run_duration(run, @now))}
                </span>
                <time
                  :if={run.gh_created_at}
                  datetime={DateTime.to_iso8601(run.gh_created_at)}
                  title={Calendar.strftime(run.gh_created_at, "%Y-%m-%d %H:%M UTC")}
                  class="whitespace-nowrap text-right text-xs tabular-nums text-ink-3"
                >
                  {JobStatus.ago(run.gh_created_at, @now)} ago
                </time>
              </li>
            </ul>
          </.panel>

          <.panel id="sizing" title="Right-sizing">
            <:subtitle>
              From each job's last runs over 30 days. Memory is what limits how many jobs a box takes at once.
            </:subtitle>
            <:actions :if={@repo_issue}>
              <SizingComponents.issue_actions
                id="sizing-repo-issue"
                issue={@repo_issue}
                label="File one issue"
                compact
              />
            </:actions>
            <p :if={@hints == []} id="sizing-empty" class="text-sm text-ink-3">
              <%= if @dismissed_hints == [] do %>
                Nothing to change. A job needs 5 complete runs on its size before Crew suggests a smaller one.
              <% else %>
                Nothing left to change: every hint is dismissed.
              <% end %>
            </p>
            <ul :if={@hints != []} id="sizing-hints" class="-my-3 divide-y divide-line">
              <li
                :for={h <- @hints}
                id={"sizing-#{h.job.id}"}
                class="grid gap-x-6 gap-y-1.5 py-3 sm:grid-cols-[minmax(0,13rem)_minmax(0,1fr)_auto] sm:items-start"
              >
                <div class="min-w-0">
                  <.link
                    navigate={
                      ~p"/runs/#{h.job.github_run_id}/attempts/#{h.job.run_attempt}/jobs/#{h.job.github_id}"
                    }
                    class="text-sm font-medium text-ink underline-offset-2 hover:underline"
                  >
                    {h.workflow_name} · {h.name}
                  </.link>
                  <p class="mt-0.5 text-xs text-ink-3">{SizingComponents.shape(h.hint.from)}</p>
                </div>
                <div class="min-w-0">
                  <.badge color={SizingComponents.color(h.hint)}>
                    {SizingComponents.title(h.hint)}
                  </.badge>
                  <p class="mt-1 text-xs text-ink-2">{List.first(h.hint.reasons)}</p>
                </div>
                <div class="space-y-1 sm:text-right">
                  <p class="whitespace-nowrap text-xs text-ink-2">
                    {SizingComponents.saving(h.hint)}
                  </p>
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1 sm:justify-end">
                    <SizingComponents.issue_actions
                      :if={h.issue}
                      id={"sizing-#{h.job.id}-issue"}
                      issue={h.issue}
                      compact
                    />
                    <.link
                      :if={Scope.admin?(@current_scope) and h.hint.kind == :custom}
                      href={SizingComponents.add_size_path(h.hint.to, [@repo.id])}
                      class="whitespace-nowrap text-xs text-ink-2 underline-offset-2 hover:text-ink hover:underline"
                    >
                      Add this size
                    </.link>
                    <SizingComponents.dismiss_button
                      :if={Scope.admin?(@current_scope) and @dismissing != h.job.id}
                      job_id={h.job.id}
                    />
                  </div>
                </div>
                <SizingComponents.dismiss_form
                  :if={Scope.admin?(@current_scope) and @dismissing == h.job.id}
                  id={"sizing-#{h.job.id}-dismiss"}
                  job_id={h.job.id}
                  hint={h.hint}
                  class="sm:col-span-3 sm:justify-end"
                />
              </li>
            </ul>
            <SizingComponents.dismissed_list
              hints={@dismissed_hints}
              open={@show_dismissed}
              admin={Scope.admin?(@current_scope)}
            />
          </.panel>

          <UsageComponents.repo_panel summary={@usage} days={@days} />
        </div>

        <aside class="min-w-0 space-y-4" aria-label="Configuration">
          <.panel :if={Scope.admin?(@current_scope)} id="settings" title="Settings">
            <.form for={@form} id="repo-settings" phx-submit="save" class="space-y-1">
              <.input field={@form[:enabled]} type="checkbox" label="Run this repo's Crew jobs" />
              <fieldset class="mb-3">
                <legend class="label">Allowed sizes</legend>
                <p class="mb-2 text-xs text-ink-3">None ticked: every size.</p>
                <input type="hidden" name="repo[allowed_sizes][]" value="" />
                <div class="flex flex-wrap gap-x-4 gap-y-2">
                  <label :for={size <- @sizes} class="flex items-center gap-2 text-sm text-ink">
                    <input
                      type="checkbox"
                      class="checkbox"
                      name="repo[allowed_sizes][]"
                      value={size.name}
                      checked={size.name in (@form[:allowed_sizes].value || [])}
                    />
                    {size.name}
                  </label>
                </div>
              </fieldset>
              <.input
                field={@form[:max_concurrent]}
                type="number"
                label="Most VMs at once (blank: no cap)"
              />
              <.input
                field={@form[:fork_prs]}
                type="select"
                label="Fork PRs"
                options={[{"Refuse", "refuse"}, {"Allow", "allow"}]}
              />
              <.input
                field={@form[:priority]}
                type="number"
                label="Priority (higher is placed first)"
              />
              <div class="pt-2">
                <.button type="submit" variant="primary" size="sm">Save</.button>
              </div>
            </.form>
          </.panel>

          <.panel :if={Scope.admin?(@current_scope)} id="schedules" title="Schedules">
            <:subtitle>
              Crew starts these workflows on time, with <code>workflow_dispatch</code>, where GitHub's own
              <code>schedule:</code>
              trigger can run hours late. Each workflow needs a <code>workflow_dispatch</code>
              trigger; drop its <code>schedule:</code>
              so GitHub doesn't start it again later. Times are UTC.
            </:subtitle>
            <p :if={@schedules == []} id="schedules-empty" class="text-sm text-ink-3">
              No schedules yet.
            </p>
            <ul :if={@schedules != []} id="schedules-list" class="-my-3 divide-y divide-line">
              <li :for={s <- @schedules} id={"schedule-#{s.id}"} class="space-y-1.5 py-3">
                <div class="min-w-0">
                  <p class="text-sm text-ink">
                    <span class="font-mono">{s.workflow}</span>
                    <span class="text-ink-3">on</span>
                    <span class="font-mono">{s.ref}</span>
                    <.badge :if={!s.enabled} size="sm" class="ml-1">Off</.badge>
                  </p>
                  <p class="mt-0.5 text-xs text-ink-3">
                    <code class="rounded-md border border-line bg-subtle px-1.5 py-0.5 font-mono text-ink-2">{s.cron}</code>
                    <span :if={s.enabled}>
                      · next <.local_time id={"schedule-#{s.id}-next"} at={Schedules.next_at(s)} />
                    </span>
                    <span :if={s.last_dispatched_at}>
                      · last started
                      <.local_time
                        id={"schedule-#{s.id}-last"}
                        at={s.last_dispatched_at}
                        format="relative"
                      />
                    </span>
                  </p>
                  <p :if={s.last_error} class="mt-0.5 text-xs text-danger">
                    Last dispatch failed: {s.last_error}
                  </p>
                </div>
                <div class="space-x-3 whitespace-nowrap text-xs">
                  <button
                    type="button"
                    phx-click="run_schedule"
                    phx-value-id={s.id}
                    class="underline-offset-2 hover:underline"
                  >Run now</button>
                  <button
                    type="button"
                    phx-click="toggle_schedule"
                    phx-value-id={s.id}
                    class="underline-offset-2 hover:underline"
                  >{if s.enabled, do: "Disable", else: "Enable"}</button>
                  <button
                    type="button"
                    phx-click="delete_schedule"
                    phx-value-id={s.id}
                    data-confirm={"Remove the schedule for #{s.workflow}?"}
                    class="text-danger underline-offset-2 hover:underline"
                  >Remove</button>
                </div>
              </li>
            </ul>
            <.form
              for={@schedule_form}
              id="schedule-form"
              phx-submit="create_schedule"
              class="mt-4 space-y-1"
            >
              <.input
                field={@schedule_form[:workflow]}
                label="Workflow file"
                placeholder="flake-hunt.yml"
              />
              <.input field={@schedule_form[:ref]} label="Branch or tag" />
              <.input field={@schedule_form[:cron]} label="Cron (UTC)" placeholder="17 7 * * *" />
              <div class="pt-2">
                <.button type="submit" size="sm">Add schedule</.button>
              </div>
            </.form>
          </.panel>

          <.panel id="snippets" title="runs-on">
            <:subtitle>
              Copy one into a job. Only runners with exactly that label take its jobs.
            </:subtitle>
            <ul class="space-y-2">
              <li
                :for={size <- allowed(@repo, @sizes)}
                class="flex items-center justify-between gap-3"
              >
                <code class="whitespace-nowrap rounded-md border border-line bg-subtle px-2 py-1 font-mono text-xs text-ink">runs-on: crew-{size.name}</code>
                <span class="text-xs text-ink-3">
                  {size.vcpus} vCPU · {div(size.memory_mib, 1024)} GiB · {size.disk_gib} GiB disk
                </span>
              </li>
            </ul>
            <p
              :if={(examples = spare_examples(allowed(@repo, @sizes), @sizes)) != []}
              id="spare-hint"
              class="mt-3 text-xs text-ink-3"
            >
              Add <code class="font-mono text-ink-2">-spare</code>
              for background work that only gets room regular jobs aren't using:
              <%= for {label, i} <- Enum.with_index(examples) do %>
                <span :if={i > 0}>or</span>
                <code class="font-mono text-ink-2">runs-on: {label}</code>
              <% end %>.
            </p>
          </.panel>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :totals, :map, required: true

  # The window's numbers in one strip: the counts and rates that say how
  # the repo's CI is doing, each with the number behind it.
  defp stats(assigns) do
    ~H"""
    <.panel id="stats" padded={false}>
      <dl class="grid grid-cols-2 divide-y divide-line sm:grid-cols-3 sm:divide-x xl:grid-cols-6 xl:divide-y-0">
        <.stat
          id="stat-jobs"
          label="Jobs"
          value={delimit(@totals.jobs)}
          note={"#{delimit(@totals.success)} passed · #{delimit(@totals.failure)} failed" <>
            if(@totals.other > 0, do: " · #{delimit(@totals.other)} other", else: "")}
        />
        <.stat
          id="stat-pass-rate"
          label="Pass rate"
          value={pct(@totals.pass_rate)}
          note="of passed and failed; timed out counts as failed"
        />
        <.stat
          id="stat-run"
          label="Run time, p50"
          value={JobStatus.format(@totals.run_p50)}
          note={"p95 #{JobStatus.format(@totals.run_p95)}"}
        />
        <.stat
          id="stat-wait"
          label="Queue wait, p50"
          value={JobStatus.format(@totals.wait_p50)}
          note={"p95 #{JobStatus.format(@totals.wait_p95)}"}
        />
        <.stat
          id="stat-minutes"
          label="Job minutes"
          value={minutes(@totals.job_s)}
          note={"#{delimit(@totals.job_billable_min)} rounded up"}
        />
        <.stat
          id="stat-flaky"
          label="Flaky jobs"
          value={delimit(@totals.flaky_jobs)}
          note="failed, then passed on a re-run"
        />
      </dl>
    </.panel>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 px-5 py-4">
      <dt class="text-xs text-ink-3">{@label}</dt>
      <dd class="mt-1 text-2xl font-semibold leading-none text-ink">{@value}</dd>
      <dd :if={@note} class="mt-1.5 text-xs text-ink-3">{@note}</dd>
    </div>
    """
  end

  attr :rate, :any, required: true

  # A pass rate as a number with a meter under it, so a column of them scans.
  defp pass_rate(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="w-9 shrink-0 text-right tabular-nums text-ink-2">{pct(@rate)}</span>
      <span class="h-1 w-16 shrink-0 overflow-hidden rounded-full bg-line" aria-hidden="true">
        <span
          :if={@rate}
          class={["block h-full rounded-full", if(@rate >= 0.9, do: "bg-success", else: "bg-warning")]}
          style={"width: #{round(@rate * 100)}%"}
        />
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :insights, :map, required: true

  # Jobs completed per UTC day, stacked by outcome. Outcomes are status,
  # so they take the status hues: green passed, red failed, gray other.
  defp jobs_chart(assigns) do
    series = assigns.insights.series
    point = fn key -> Enum.map(series, &{day_at(&1.day), &1[key]}) end

    [success, failure, other] =
      Geometry.stack([point.(:success), point.(:failure), point.(:other)])

    t = assigns.insights.totals

    lines = [
      %{
        label: "Passed",
        color: Charts.series_color(2),
        kind: :area,
        points: success,
        value: delimit(t.success)
      },
      %{
        label: "Failed",
        color: Charts.series_color(7),
        kind: :area,
        points: failure,
        value: delimit(t.failure)
      },
      %{
        label: "Other",
        color: Charts.other_color(),
        kind: :area,
        points: other,
        value: delimit(t.other)
      }
    ]

    top = series |> Enum.map(&(&1.success + &1.failure + &1.other)) |> Enum.max(fn -> 0 end)

    assigns =
      assign(assigns,
        series: lines,
        since: day_at(assigns.insights.from),
        until: day_at(assigns.insights.to),
        ymax: Geometry.nice_max(top)
      )

    ~H"""
    <Charts.timeseries
      id={@id}
      title="Jobs per day"
      note="by outcome; UTC days"
      series={@series}
      since={@since}
      until={@until}
      ymax={@ymax}
      gap={86_400}
      days
      format={&jobs_label/1}
      empty="No jobs in this range."
    />
    """
  end

  attr :id, :string, required: true
  attr :insights, :map, required: true

  # Run time per UTC day: the p50 and p95 as two lines, the p95 muted.
  # Days with no jobs break the lines rather than drawing as zero.
  defp run_time_chart(assigns) do
    with_runs = Enum.filter(assigns.insights.series, & &1.run_p50)
    t = assigns.insights.totals

    lines = [
      %{
        label: "p95",
        color: Charts.other_color(),
        kind: :line,
        points: Enum.map(with_runs, &{day_at(&1.day), &1.run_p95}),
        value: JobStatus.format(t.run_p95)
      },
      %{
        label: "p50",
        color: Charts.series_color(0),
        kind: :line,
        points: Enum.map(with_runs, &{day_at(&1.day), &1.run_p50}),
        value: JobStatus.format(t.run_p50)
      }
    ]

    top = with_runs |> Enum.map(& &1.run_p95) |> Enum.max(fn -> 0 end)

    assigns =
      assign(assigns,
        series: lines,
        since: day_at(assigns.insights.from),
        until: day_at(assigns.insights.to),
        ymax: Geometry.nice_max(top)
      )

    ~H"""
    <Charts.timeseries
      id={@id}
      title="Run time"
      note="p50 and p95 per day; UTC days"
      series={@series}
      since={@since}
      until={@until}
      ymax={@ymax}
      gap={86_400}
      days
      format={&JobStatus.format(round(&1))}
      empty="No jobs in this range."
    />
    """
  end

  defp jobs_label(x), do: "#{x |> round() |> delimit()} jobs"

  defp day_at(day), do: day |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
end
