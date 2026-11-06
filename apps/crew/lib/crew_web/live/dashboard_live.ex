defmodule CrewWeb.DashboardLive do
  @moduledoc """
  The dashboard (§17.3): the fleet strip (a card per box with its last
  half hour of CPU and memory, what's allocated of what it offers, VMs by
  size and its status), running, waiting and booting counts, the longest
  waits with their reasons, the last completed jobs, the day's charts,
  and the activity feed. Fleet-wide, so members see jobs of repos they
  can't read as "a job in another repo" (§18.3).

  It refreshes every 5 s, and the activity feed as events come.
  """
  use CrewWeb, :live_view

  alias Crew.{Boxes, Jobs, Repos}
  alias CrewWeb.{BoxCard, Charts, JobStatus}
  alias CrewWeb.Charts.Geometry

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:activity, Crew.Activity.recent(socket.assigns.current_scope, 20))
     |> load()}
  end

  defp load(socket) do
    now = DateTime.utc_now()
    boxes = Boxes.list()

    assign(socket,
      now: now,
      readable: Repos.readable_ids(socket.assigns.current_scope),
      fleet: Enum.map(boxes, &BoxCard.load/1),
      counts: Jobs.counts(),
      waiting: Jobs.longest_waiting(10),
      recent: Jobs.recently_completed(20),
      started: Crew.Cache.fetch(:started_series, chart_cache_ms(), &Jobs.started_series/0),
      phases: Crew.Cache.fetch(:phase_series, chart_cache_ms(), &Jobs.phase_series/0),
      repos?: Repos.list() != []
    )
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  # The feed updates live (UserAuth shows the notice and passes it on).
  def handle_info({:activity, event}, socket) do
    event = Crew.Activity.for_scope(event, socket.assigns.current_scope)
    {:noreply, update(socket, :activity, &Enum.take([event | &1], 20))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Every viewer sees the same day: read it once per interval.
  defp chart_cache_ms, do: Application.get_env(:crew, :chart_cache_ms, 30_000)

  defp readable?(:all, _), do: true
  defp readable?(ids, repo_id), do: repo_id in ids

  defp reason(readable, job) do
    reason = job.blocked_reason || job.wait_reason
    if readable?(readable, job.repo_id), do: reason, else: JobStatus.masked_reason(reason)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Dashboard</:breadcrumb>

      <.header>
        Dashboard
        <:subtitle>Jobs, boxes and what's waiting.</:subtitle>
      </.header>

      <.panel
        :if={
          @fleet == [] or not @repos? or (@recent == [] and @waiting == [] and @counts.running == 0)
        }
        id="dashboard-empty"
        title="Get started"
      >
        <div class="space-y-3 text-sm text-ink-2">
          <p :if={@fleet == []} id="empty-boxes">
            <.link
              navigate={~p"/boxes/new"}
              class="font-medium text-ink underline-offset-2 hover:underline"
            >Add your first box.</.link>
            Boxes are the machines that run job VMs.
          </p>
          <p :if={not @repos?} id="empty-repos">
            <span class="font-medium text-ink">Install the App on a repo.</span>
            Crew only sees jobs from repos the GitHub App is installed on.
          </p>
          <div id="empty-jobs">
            <p>Then ask for a Crew runner in a workflow:</p>
            <pre class="mt-2 rounded-lg border border-line bg-subtle px-3 py-2 font-mono text-xs text-ink">runs-on: crew-m</pre>
          </div>
        </div>
      </.panel>

      <section
        :if={@fleet != []}
        id="fleet"
        aria-label="Fleet"
        class="mb-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4"
      >
        <.link
          :for={card <- @fleet}
          id={"fleet-#{card.box.id}"}
          navigate={~p"/boxes/#{card.box.id}"}
          class="block rounded-xl border border-line bg-raised p-4 shadow-xs hover:border-line-strong"
        >
          <BoxCard.box_card card={card} />
        </.link>
      </section>

      <section id="counters" class="mb-4 grid grid-cols-3 gap-3">
        <.link
          navigate={~p"/runs?status=in_progress"}
          class="rounded-xl border border-line bg-raised p-4 shadow-xs hover:border-line-strong"
        >
          <p class="text-xs text-ink-3">Running</p>
          <p class="text-2xl font-semibold tabular-nums text-ink">{@counts.running}</p>
        </.link>
        <.link
          navigate={~p"/runs?status=queued"}
          class="rounded-xl border border-line bg-raised p-4 shadow-xs hover:border-line-strong"
        >
          <p class="text-xs text-ink-3">Waiting</p>
          <p class="text-2xl font-semibold tabular-nums text-ink">{@counts.waiting}</p>
        </.link>
        <.link
          navigate={~p"/queue"}
          class="rounded-xl border border-line bg-raised p-4 shadow-xs hover:border-line-strong"
        >
          <p class="text-xs text-ink-3">Booting</p>
          <p class="text-2xl font-semibold tabular-nums text-ink">{@counts.booting}</p>
        </.link>
      </section>

      <div class="mb-4 grid gap-4 lg:grid-cols-2">
        <.panel id="waiting" title="Waiting longest" padded={false}>
          <ul class="divide-y divide-line text-sm">
            <li :for={job <- @waiting} class="flex items-start justify-between gap-3 px-5 py-2.5">
              <span class="min-w-0">
                <%= if readable?(@readable, job.repo_id) do %>
                  <span class="block truncate text-ink">{job.name}</span>
                  <span class="block truncate text-xs text-ink-3">{job.repo.full_name}</span>
                <% else %>
                  <span class="block truncate text-ink-2">a job in another repo</span>
                  <span class="block text-xs text-ink-3">{job.size && job.size.name}</span>
                <% end %>
                <span :if={job.blocked_reason || job.wait_reason} class="block text-xs text-warning">
                  {reason(@readable, job)}
                </span>
              </span>
              <span class="shrink-0 tabular-nums text-xs text-ink-3">
                {JobStatus.format(JobStatus.duration(job.queued_at || job.seen_at, @now))}
              </span>
            </li>
            <li :if={@waiting == []} class="px-5 py-3 text-ink-3">Nothing is waiting.</li>
          </ul>
        </.panel>

        <.panel id="recent" title="Recently completed" padded={false}>
          <ul class="divide-y divide-line text-sm">
            <li :for={job <- @recent} class="flex items-center justify-between gap-3 px-5 py-2.5">
              <span class="min-w-0 truncate">
                <%= if readable?(@readable, job.repo_id) do %>
                  <span class="text-ink">{job.name}</span>
                  <span class="text-xs text-ink-3"> · {job.repo.full_name}</span>
                <% else %>
                  <span class="text-ink-2">a job in another repo</span>
                <% end %>
              </span>
              <.job_status job={job} now={@now} />
            </li>
            <li :if={@recent == []} class="px-5 py-3 text-ink-3">None yet.</li>
          </ul>
        </.panel>
      </div>

      <div class="mb-4 grid gap-4 lg:grid-cols-2">
        <Charts.timeseries
          id="chart-started"
          title="Jobs started, 24 hours"
          note="per 5 minutes, by conclusion"
          series={started_series(@started)}
          since={@started.since}
          until={@started.until}
          ymax={Geometry.nice_max(stack_max(@started))}
          gap={900}
          format={&to_string(round(&1))}
          empty="No Crew jobs started today."
        />
        <Charts.timeseries
          id="chart-wait"
          title="Wait and boot, 24 hours"
          note="p50 and p95 per hour"
          series={phase_series(@phases)}
          since={@phases.since}
          until={@phases.until}
          ymax={Geometry.nice_max(phase_max(@phases))}
          gap={7200}
          format={&JobStatus.format(round(&1))}
          empty="No placements today."
        />
      </div>

      <.panel id="activity" title="Activity" padded={false}>
        <ul :if={@activity != []} class="divide-y divide-line">
          <li :for={event <- @activity} id={"activity-#{event.id}"} class="px-5 py-2.5 text-sm">
            <span class="text-ink">{event.message}</span>
            <span class="ml-2 text-xs text-ink-3">
              {Calendar.strftime(event.inserted_at, "%b %-d, %H:%M UTC")}
            </span>
          </li>
        </ul>
        <p :if={@activity == []} class="px-5 py-4 text-sm text-ink-3">Nothing yet.</p>
      </.panel>
    </Layouts.app>
    """
  end

  defp started_series(s) do
    [success, failure, other] = Geometry.stack([s.success, s.failure, s.other])

    [
      %{label: "Succeeded", color: Charts.series_color(1), kind: :area, points: success},
      %{label: "Failed", color: Charts.series_color(3), kind: :area, points: failure},
      %{label: "Other", color: Charts.other_color(), kind: :area, points: other}
    ]
  end

  defp stack_max(s) do
    [s.success, s.failure, s.other]
    |> Enum.zip()
    |> Enum.map(fn {{_, a}, {_, b}, {_, c}} -> a + b + c end)
    |> Enum.max(fn -> 1 end)
  end

  defp phase_series(p) do
    [
      %{
        label: "Wait p50",
        color: Charts.series_color(0),
        kind: :line,
        points: Enum.map(p.wait, fn {t, p50, _} -> {t, p50} end)
      },
      %{
        label: "Wait p95",
        color: Charts.series_color(4),
        kind: :line,
        points: Enum.map(p.wait, fn {t, _, p95} -> {t, p95} end)
      },
      %{
        label: "Boot p50",
        color: Charts.series_color(2),
        kind: :line,
        points: Enum.map(p.boot, fn {t, p50, _} -> {t, p50} end)
      },
      %{
        label: "Boot p95",
        color: Charts.series_color(5),
        kind: :line,
        points: Enum.map(p.boot, fn {t, _, p95} -> {t, p95} end)
      }
    ]
  end

  defp phase_max(p), do: (p.wait ++ p.boot) |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> 60 end)
end
