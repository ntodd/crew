defmodule CrewWeb.RunLive.Index do
  @moduledoc """
  Runs (§17.3): run attempts newest first, earlier attempts folded under
  the latest, with filters kept in the URL. The stack view groups them
  by branch, with runs of an older head SHA folded under the newest: the
  view for a stack of PRs that keeps getting rebased. Members see only repos they
  can read (§18.3). Updates arrive over PubSub, coalesced and flushed at
  most every 250 ms (§17.5).
  """
  use CrewWeb, :live_view

  alias Crew.{Jobs, Repos}
  alias CrewWeb.JobStatus

  import CrewWeb.GitHub

  @flush_ms 250
  @filters ~w(repo q status crew mine view)
  @toggles ~w(crew mine)
  @statuses [
    {"Queued", "queued"},
    {"In progress", "in_progress"},
    {"Succeeded", "success"},
    {"Failed", "failure"},
    {"Cancelled", "cancelled"}
  ]
  @status_values Enum.map(@statuses, &elem(&1, 1))

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Crew.PubSub, "jobs")

    {:ok,
     socket
     |> assign(:page_title, "Runs")
     |> assign(:flush_pending, false)
     |> assign(:repos, visible_repos(socket.assigns.current_scope))}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, socket |> assign(:filters, clean(params)) |> load()}

  # The filters in `params` that filter: a toggle only when it's on, a
  # status only when it's one the list knows.
  defp clean(params) do
    params
    |> Map.take(@filters)
    |> Map.reject(fn {k, v} ->
      not is_binary(v) or String.trim(v) == "" or (k in @toggles and v != "true") or
        (k == "status" and v not in @status_values)
    end)
  end

  defp load(socket) do
    runs =
      Jobs.list_runs(socket.assigns.current_scope, Map.delete(socket.assigns.filters, "view"))

    stack? = socket.assigns.filters["view"] == "stack"

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:empty, runs == [])
    |> assign(:stack, if(stack?, do: stack(runs), else: []))
    |> stream(:runs, if(stack?, do: [], else: runs),
      reset: true,
      dom_id: &"run-#{&1.github_run_id}"
    )
  end

  # Runs by repo and branch, newest branch first; in each, the newest
  # head SHA's runs, and the older SHAs' runs as superseded.
  defp stack(runs) do
    runs
    |> Enum.group_by(&{&1.repo_id, &1.head_branch})
    |> Enum.map(fn {{_repo, branch}, rs} ->
      rs = Enum.sort_by(rs, &DateTime.to_unix(&1.gh_created_at, :microsecond), :desc)
      head = hd(rs).head_sha
      {current, older} = Enum.split_with(rs, &(&1.head_sha == head))

      %{
        branch: branch,
        repo: hd(rs).repo,
        current: current,
        superseded: older,
        newest: hd(rs).gh_created_at,
        pr: hd(rs).pull_requests
      }
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.newest, :microsecond), :desc)
  end

  # Branch names repeat across repos, and slugs collide (feat/a, feat-a).
  defp stack_id(group),
    do: "stack-#{:erlang.phash2({group.repo.id, group.branch}, 4_294_967_296)}"

  defp visible_repos(scope) do
    case Repos.readable_ids(scope) do
      :all -> Repos.list()
      ids -> Enum.filter(Repos.list(), &(&1.id in ids))
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: runs_path(clean(params)))}
  end

  def handle_event("view", %{"view" => view}, socket) do
    query =
      if view == "stack",
        do: Map.put(socket.assigns.filters, "view", "stack"),
        else: Map.delete(socket.assigns.filters, "view")

    {:noreply, push_patch(socket, to: runs_path(query))}
  end

  defp status_options, do: [{"Any status", ""} | @statuses]

  defp runs_path(query) when query == %{}, do: ~p"/runs"
  defp runs_path(query), do: ~p"/runs?#{query}"

  defp filtered?(filters), do: Map.delete(filters, "view") != %{}

  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
      <:breadcrumb>Runs</:breadcrumb>

      <.header class="pb-0">
        Runs
        <:subtitle>Every workflow run on the repos Crew sees, Crew's jobs and the rest.</:subtitle>
      </.header>

      <div class="space-y-3">
        <.form
          for={%{}}
          id="run-filters"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-wrap items-center gap-2"
        >
          <input :if={@filters["view"]} type="hidden" name="view" value={@filters["view"]} />
          <div class="relative w-full sm:w-72 xl:w-80">
            <.icon
              name="hero-magnifying-glass-micro"
              class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-ink-3"
            />
            <input
              type="search"
              id="run-search"
              name="q"
              value={@filters["q"]}
              placeholder="Search branch, PR or actor"
              aria-label="Search by branch, PR or actor"
              title="Part of a branch or actor, or a PR number. branch:, pr: and actor: match exactly."
              aria-describedby="run-search-help"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="300"
              class="input pl-8"
            />
            <span id="run-search-help" class="sr-only">
              Matches part of a branch or actor, or a PR number. branch:, pr: and actor: match exactly.
            </span>
          </div>
          <.toolbar_select
            name="repo"
            label="Repo"
            value={@filters["repo"]}
            class="w-full sm:w-56"
            options={[{"All repos", ""} | Enum.map(@repos, &{&1.full_name, &1.full_name})]}
          />
          <.toolbar_select
            name="status"
            label="Status"
            value={@filters["status"]}
            class="w-full sm:w-36"
            options={status_options()}
          />
          <.toolbar_check name="crew" label="Crew jobs only" checked={@filters["crew"] == "true"} />
          <.toolbar_check name="mine" label="Mine" checked={@filters["mine"] == "true"} />
          <span class="segmented ml-auto" role="group" aria-label="View">
            <a
              id="view-list"
              href="#"
              phx-click="view"
              phx-value-view="list"
              aria-current={to_string(@filters["view"] != "stack")}
            >List</a>
            <a
              id="view-stack"
              href="#"
              phx-click="view"
              phx-value-view="stack"
              aria-current={to_string(@filters["view"] == "stack")}
            >By branch</a>
          </span>
        </.form>

        <div :if={@filters["view"] == "stack"} id="stack" class="space-y-3">
          <.panel
            :for={group <- @stack}
            id={stack_id(group)}
            data-branch={group.branch}
            title={group.branch}
            padded={false}
          >
            <:subtitle>
              <.gh_link href={repo_url(group.repo)}>{group.repo.full_name}</.gh_link>
              <span :for={pr <- group.pr || []}>
                · <.gh_link href={pr_url(group.repo, pr["number"])}>PR #{pr["number"]}</.gh_link>
              </span>
            </:subtitle>
            <ul data-current class="divide-y divide-line">
              <.run_row :for={run <- group.current} run={run} now={@now} />
            </ul>
            <details :if={group.superseded != []} data-superseded class="border-t border-line">
              <summary class="cursor-pointer px-5 py-2 text-xs text-ink-3">
                {length(group.superseded)} superseded {if length(group.superseded) == 1,
                  do: "run",
                  else: "runs"} (older commits)
              </summary>
              <ul class="divide-y divide-line opacity-75">
                <.run_row :for={run <- group.superseded} run={run} now={@now} />
              </ul>
            </details>
          </.panel>
          <.panel :if={@empty} padded={false}>
            <.runs_empty filters={@filters} />
          </.panel>
        </div>

        <.panel :if={@filters["view"] != "stack"} id="runs-panel" padded={false}>
          <ul id="runs" phx-update="stream" class="divide-y divide-line">
            <.run_row :for={{dom_id, run} <- @streams.runs} id={dom_id} run={run} now={@now} />
          </ul>
          <.runs_empty :if={@empty} filters={@filters} />
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :class, :any, default: nil

  defp toolbar_select(assigns) do
    ~H"""
    <div class={["relative", @class]}>
      <select id={"filter-#{@name}"} name={@name} aria-label={@label} class="input">
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.icon
        name="hero-chevron-up-down-micro"
        class="pointer-events-none absolute right-2.5 top-1/2 size-4 -translate-y-1/2 text-ink-3"
      />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false

  defp toolbar_check(assigns) do
    ~H"""
    <label class="inline-flex h-9 cursor-pointer select-none items-center gap-2 px-1.5 text-sm text-ink-2 transition-colors hover:text-ink has-checked:text-ink">
      <input
        type="checkbox"
        id={"filter-#{@name}"}
        name={@name}
        value="true"
        checked={@checked}
        class="checkbox"
      />
      {@label}
    </label>
    """
  end

  attr :filters, :map, required: true

  defp runs_empty(assigns) do
    ~H"""
    <%= if filtered?(@filters) do %>
      <.empty_state id="runs-empty" icon="hero-funnel">
        No runs match these filters.
        <:action>
          <.button size="sm" variant="secondary" patch={runs_path(Map.take(@filters, ["view"]))}>
            Clear filters
          </.button>
        </:action>
      </.empty_state>
    <% else %>
      <.empty_state id="runs-empty" icon="hero-play-circle">
        No runs yet. Jobs with <code class="font-mono">runs-on: crew-m</code>
        show up here as soon as GitHub queues them.
      </.empty_state>
    <% end %>
    """
  end

  attr :id, :string, default: nil
  attr :run, :map, required: true
  attr :now, :any, required: true

  # Fixed-width columns after the first, so the job bars, durations and
  # ages line up from row to row (each row is its own grid).
  defp run_row(assigns) do
    ~H"""
    <li
      id={@id}
      data-run={@run.github_run_id}
      class="grid grid-cols-[minmax(0,1fr)_4.5rem_4.5rem] items-center gap-x-6 gap-y-2 px-5 py-3 text-sm md:grid-cols-[minmax(0,1fr)_11rem_4.5rem_4.5rem]"
    >
      <div class="col-span-3 min-w-0 md:col-span-1">
        <div class="flex min-w-0 items-center gap-2">
          <.link
            navigate={~p"/runs/#{@run.github_run_id}/attempts/#{@run.run_attempt}"}
            class="flex min-w-0 items-center gap-2 font-medium text-ink hover:underline"
          >
            <.run_status_icon run={@run} />
            <span class="flex min-w-0 items-baseline gap-1.5">
              <span class="truncate">{@run.workflow_name}</span>
              <span class="shrink-0 font-normal text-ink-3">#{@run.run_number}</span>
            </span>
          </.link>
          <span
            :if={@run.run_attempt > 1}
            class="inline-flex shrink-0 items-baseline gap-1.5 text-xs text-ink-3"
          >
            <span>· attempt {@run.run_attempt}, earlier</span>
            <.link
              :for={n <- @run.earlier_attempts}
              navigate={~p"/runs/#{@run.github_run_id}/attempts/#{n}"}
              class="underline underline-offset-2 hover:text-ink"
            >#{n}</.link>
          </span>
        </div>
        <p class="mt-0.5 truncate pl-6 text-xs text-ink-3">
          <.gh_link href={repo_url(@run.repo)}>{@run.repo.full_name}</.gh_link>
          ·
          <%= case pr_number(@run) do %>
            <% nil -> %>
              <.gh_link href={branch_url(@run.repo, @run.head_branch)}>{@run.head_branch}</.gh_link>
            <% n -> %>
              <.gh_link href={pr_url(@run.repo, n)}>PR #{n}</.gh_link>
          <% end %>
          <span :if={@run.head_sha}>
            ·
            <.gh_link href={commit_url(@run.repo, @run.head_sha)} class="font-mono">{short(
              @run.head_sha
            )}</.gh_link>
          </span>
          <span :if={@run.actor_login}> · {@run.actor_login}</span>
        </p>
      </div>
      <div class="flex min-w-0 items-center gap-3">
        <.job_bar id={"bar-#{@run.id}"} jobs={@run.jobs} now={@now} />
        <span class="whitespace-nowrap text-xs tabular-nums text-ink-3">
          {length(@run.jobs)} {if length(@run.jobs) == 1, do: "job", else: "jobs"}
        </span>
      </div>
      <span title="Duration" class="text-right text-xs tabular-nums text-ink-2">
        {JobStatus.format(run_duration(@run, @now))}
      </span>
      <time
        datetime={DateTime.to_iso8601(@run.gh_created_at)}
        title={Calendar.strftime(@run.gh_created_at, "%Y-%m-%d %H:%M UTC")}
        class="whitespace-nowrap text-right text-xs tabular-nums text-ink-3"
      >
        {JobStatus.ago(@run.gh_created_at, @now)} ago
      </time>
    </li>
    """
  end

  defp pr_number(%{pull_requests: [%{"number" => n} | _]}), do: n
  defp pr_number(_run), do: nil

  defp short(nil), do: ""
  defp short(sha), do: String.slice(sha, 0, 7)

  defp run_duration(%{status: "completed", gh_created_at: from, gh_updated_at: to}, _now),
    do: JobStatus.duration(from, to)

  defp run_duration(%{gh_created_at: from}, now), do: JobStatus.duration(from, now)
end
