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

  @flush_ms 250
  @filters ~w(repo branch pr status actor mine view)

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
  def handle_params(params, _uri, socket) do
    filters = params |> Map.take(@filters) |> Map.reject(fn {_, v} -> v in [nil, ""] end)
    {:noreply, socket |> assign(:filters, filters) |> load()}
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

  defp slug(text),
    do:
      (text || "") |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  defp visible_repos(scope) do
    case Repos.readable_ids(scope) do
      :all -> Repos.list()
      ids -> Enum.filter(Repos.list(), &(&1.id in ids))
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(@filters)
      |> Map.reject(fn {k, v} -> v in [nil, "", "false"] or (k == "mine" and v != "true") end)

    {:noreply, push_patch(socket, to: ~p"/runs?#{query}")}
  end

  def handle_event("view", %{"view" => view}, socket) do
    query =
      if view == "stack",
        do: Map.put(socket.assigns.filters, "view", "stack"),
        else: Map.delete(socket.assigns.filters, "view")

    {:noreply, push_patch(socket, to: if(query == %{}, do: ~p"/runs", else: ~p"/runs?#{query}"))}
  end

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
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Runs</:breadcrumb>

      <.header>
        Runs
        <:subtitle>Every workflow run on the repos Crew sees, Crew's jobs and the rest.</:subtitle>
      </.header>

      <div class="mb-3 flex justify-end">
        <span class="segmented" role="group" aria-label="View">
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
      </div>

      <.form for={%{}} id="run-filters" phx-change="filter" class="flex flex-wrap items-end gap-3">
        <input :if={@filters["view"]} type="hidden" name="view" value={@filters["view"]} />
        <div class="w-56">
          <.input
            type="select"
            name="repo"
            label="Repo"
            value={@filters["repo"]}
            options={[{"All repos", ""} | Enum.map(@repos, &{&1.full_name, &1.full_name})]}
          />
        </div>
        <div class="w-40">
          <.input
            type="select"
            name="status"
            label="Status"
            value={@filters["status"]}
            options={[
              {"Any", ""},
              {"Queued", "queued"},
              {"In progress", "in_progress"},
              {"Succeeded", "success"},
              {"Failed", "failure"},
              {"Cancelled", "cancelled"}
            ]}
          />
        </div>
        <div class="w-40">
          <.input name="branch" label="Branch" value={@filters["branch"]} phx-debounce="300" />
        </div>
        <div class="w-24">
          <.input name="pr" label="PR" value={@filters["pr"]} phx-debounce="300" />
        </div>
        <div class="w-36">
          <.input name="actor" label="Actor" value={@filters["actor"]} phx-debounce="300" />
        </div>
        <div class="pb-3">
          <.input type="checkbox" name="mine" label="Mine" value={@filters["mine"] == "true"} />
        </div>
      </.form>

      <div :if={@filters["view"] == "stack"} id="stack" class="space-y-3">
        <.panel :for={group <- @stack} id={"stack-#{slug(group.branch)}"} padded={false}>
          <:subtitle>
            <span class="font-medium text-ink">{group.branch}</span>
            · {group.repo.full_name}<span :for={pr <- group.pr || []}> · PR #{pr["number"]}</span>
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
        <.empty_state :if={@empty} id="runs-empty" icon="hero-play-circle">No runs yet.</.empty_state>
      </div>

      <.panel :if={@filters["view"] != "stack"} id="runs-panel" padded={false}>
        <ul id="runs" phx-update="stream" class="divide-y divide-line">
          <.run_row :for={{dom_id, run} <- @streams.runs} id={dom_id} run={run} now={@now} />
        </ul>
        <.empty_state :if={@empty} id="runs-empty" icon="hero-play-circle">
          No runs yet. Jobs with <code class="font-mono">runs-on: crew-m</code>
          show up here as soon as GitHub queues them.
        </.empty_state>
      </.panel>
    </Layouts.app>
    """
  end

  attr :id, :string, default: nil
  attr :run, :map, required: true
  attr :now, :any, required: true

  defp run_row(assigns) do
    ~H"""
    <li
      id={@id}
      data-run={@run.github_run_id}
      class="grid gap-x-4 gap-y-1.5 px-5 py-3 text-sm md:grid-cols-[minmax(0,2fr)_minmax(0,1.3fr)_auto_auto] md:items-center"
    >
      <div class="min-w-0">
        <.link
          navigate={~p"/runs/#{@run.github_run_id}/attempts/#{@run.run_attempt}"}
          class="flex min-w-0 items-center gap-2 font-medium text-ink hover:underline"
        >
          <.run_icon run={@run} />
          <span class="truncate">{@run.workflow_name}</span>
          <span class="shrink-0 text-ink-3">#{@run.run_number}</span>
        </.link>
        <p class="mt-0.5 truncate text-xs text-ink-3">
          {@run.repo.full_name} · {branch_or_pr(@run)} ·
          <span class="font-mono">{short(@run.head_sha)}</span>
          <span :if={@run.actor_login}> · {@run.actor_login}</span>
        </p>
      </div>
      <div class="flex min-w-0 items-center gap-3">
        <.job_bar id={"bar-#{@run.id}"} jobs={@run.jobs} now={@now} />
        <span class="text-xs text-ink-3">{length(@run.jobs)} {if length(@run.jobs) == 1,
          do: "job",
          else: "jobs"}</span>
      </div>
      <div class="text-xs text-ink-2">
        <span :if={@run.run_attempt > 1} class="text-ink-3">
          attempt {@run.run_attempt} ·
          <.link
            :for={n <- @run.earlier_attempts}
            navigate={~p"/runs/#{@run.github_run_id}/attempts/#{n}"}
            class="underline"
          >#{n}</.link>
        </span>
      </div>
      <div class="flex gap-3 text-xs tabular-nums text-ink-3 md:justify-end">
        <span title="Duration">{JobStatus.format(run_duration(@run, @now))}</span>
        <span title="Age">{JobStatus.ago(@run.gh_created_at, @now)} ago</span>
      </div>
    </li>
    """
  end

  attr :run, :map, required: true

  defp run_icon(assigns) do
    ~H"""
    <span class={["shrink-0", run_tone(@run)]}>
      <.icon name={run_icon_name(@run)} class="size-4" />
      <span class="sr-only">{run_label(@run)}</span>
    </span>
    """
  end

  defp run_icon_name(%{status: "completed", conclusion: "success"}), do: "hero-check-circle"
  defp run_icon_name(%{status: "completed", conclusion: "failure"}), do: "hero-x-circle"
  defp run_icon_name(%{status: "completed"}), do: "hero-no-symbol"
  defp run_icon_name(%{status: "in_progress"}), do: "hero-play-circle"
  defp run_icon_name(_), do: "hero-clock"

  defp run_tone(%{status: "completed", conclusion: "success"}), do: "text-success"
  defp run_tone(%{status: "completed", conclusion: "failure"}), do: "text-danger"
  defp run_tone(%{status: "in_progress"}), do: "text-accent-ink"
  defp run_tone(_), do: "text-ink-3"

  defp run_label(%{status: "completed", conclusion: c}), do: c || "completed"
  defp run_label(%{status: s}), do: s || "queued"

  defp branch_or_pr(%{pull_requests: [%{"number" => n} | _]}), do: "PR ##{n}"
  defp branch_or_pr(%{head_branch: branch}), do: branch

  defp short(nil), do: ""
  defp short(sha), do: String.slice(sha, 0, 7)

  defp run_duration(%{status: "completed", gh_created_at: from, gh_updated_at: to}, _now),
    do: JobStatus.duration(from, to)

  defp run_duration(%{gh_created_at: from}, now), do: JobStatus.duration(from, now)
end
