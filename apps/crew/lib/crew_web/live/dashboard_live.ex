defmodule CrewWeb.DashboardLive do
  @moduledoc """
  Live fleet capacity, workload and 24-hour trends (§17.3). Aggregate
  metrics are shared. Job details and activity respect repository access.
  """
  use CrewWeb, :live_view

  alias Crew.{Jobs, Repos, Usage}
  alias CrewWeb.{Charts, Fleet, JobStatus, UsageComponents}
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
    today = DateTime.to_date(now)

    [yesterday_usage, today_usage] =
      Crew.Cache.fetch({:dashboard_usage, today}, chart_cache_ms(), fn ->
        Usage.daily(Date.add(today, -1), today)
      end)

    started = Crew.Cache.fetch(:started_series, chart_cache_ms(), &Jobs.started_series/0)
    starts_chart = started_series(started)

    assign(socket,
      starts_chart: starts_chart,
      starts_total: Enum.sum_by(starts_chart, & &1.total),
      now: now,
      readable: Repos.readable_ids(socket.assigns.current_scope),
      fleet:
        Crew.Cache.fetch(:dashboard_fleet, min(chart_cache_ms(), @refresh_ms), &Fleet.overview/0),
      outcomes:
        Crew.Cache.fetch(:completed_outcomes, chart_cache_ms(), &Jobs.completed_outcomes/0),
      counts: Jobs.counts(),
      waiting: Jobs.longest_waiting(10),
      recent: Jobs.recently_completed(20),
      started: started,
      phases: Crew.Cache.fetch(:phase_series, chart_cache_ms(), &Jobs.phase_series/0),
      repos?: Repos.list() != [],
      job_minutes: %{today: today_usage.job_s, yesterday: yesterday_usage.job_s}
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

  attr :navigate, :string, required: true
  slot :inner_block, required: true

  defp drilldown(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="inline-flex items-center gap-1 text-xs font-medium text-ink-2 hover:text-accent-ink"
    >
      {render_slot(@inner_block)} <.icon name="hero-arrow-right-micro" class="size-3.5" />
    </.link>
    """
  end

  attr :job, :map, required: true

  defp job_link(assigns) do
    ~H"""
    <.link
      :if={@job.run_attempt_id}
      navigate={~p"/runs/#{@job.github_run_id}/attempts/#{@job.run_attempt}/jobs/#{@job.github_id}"}
      class="font-medium text-ink underline-offset-2 hover:underline"
    >
      {@job.name}
    </.link>
    <span :if={!@job.run_attempt_id}>{@job.name}</span>
    """
  end

  attr :label, :string, required: true
  attr :used, :integer, required: true
  attr :total, :integer, required: true
  attr :memory, :boolean, default: false

  defp allocation(assigns) do
    ~H"""
    <div>
      <p class="text-xs font-medium text-ink-2">{@label}</p>
      <p class="fleet-figure">
        {if @memory, do: gib(@used), else: @used}<span> / {if @memory,
          do: gib(@total) <> " GiB",
          else: @total}</span>
      </p>
      <progress
        :if={@total > 0}
        aria-label={@label}
        value={min(@used, @total)}
        max={@total}
        class="bar mt-2"
      ></progress>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :value_id, :string, default: nil
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :tone, :string, required: true
  slot :inner_block, required: true

  defp metric(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group min-w-0 rounded-xl border border-line bg-raised px-5 py-4 transition-colors hover:border-line-strong"
    >
      <div class="flex items-center justify-between gap-2">
        <p class="text-xs font-medium text-ink-2">{@label}</p>
        <.icon name={@icon} class={["size-4 shrink-0", @tone]} />
      </div>
      <p id={@value_id} class="mt-2 text-2xl font-semibold tracking-tight tabular-nums text-ink">
        {@value}
      </p>
      <p class="mt-0.5 text-xs text-ink-3">{render_slot(@inner_block)}</p>
    </.link>
    """
  end

  defp percent(nil), do: "—"
  defp percent(n), do: "#{n}%"

  attr :counts, :map, required: true

  defp outcome_panel(assigns) do
    counts = assigns.counts
    total = Enum.sum(Map.values(counts))
    succeeded = Map.get(counts, "success", 0)

    other =
      counts |> Map.drop(~w(success failure cancelled skipped)) |> Map.values() |> Enum.sum()

    slices =
      [
        {"Succeeded", succeeded, "text-success"},
        {"Failed", Map.get(counts, "failure", 0), "text-danger"},
        {"Cancelled", Map.get(counts, "cancelled", 0), "text-warning"},
        {"Skipped", Map.get(counts, "skipped", 0), "text-ink-3"}
      ] ++ if other > 0, do: [{"Other", other, "text-running-ink"}], else: []

    {rows, _} =
      Enum.map_reduce(slices, 0, fn {label, count, color}, start ->
        share = if total > 0, do: 100 * count / total, else: 0
        {%{label: label, count: count, color: color, share: share, offset: -start}, start + share}
      end)

    assigns =
      assign(assigns,
        rows: rows,
        total: total,
        rate: if(total > 0, do: round(100 * succeeded / total))
      )

    ~H"""
    <section
      id="job-outcomes"
      class="min-w-0 rounded-xl border border-line bg-raised px-5 py-4 lg:col-span-2 xl:col-span-1"
    >
      <h2 class="text-sm font-semibold text-ink">Job outcomes</h2>
      <p class="mt-0.5 text-xs text-ink-3">{UsageComponents.delimit(@total)} completed in 24h</p>
      <div class="mt-4 flex flex-wrap items-center justify-center gap-x-6 gap-y-3 xl:flex-col">
        <div class="relative grid size-24 shrink-0 place-items-center">
          <svg viewBox="0 0 100 100" class="absolute inset-0 size-full -rotate-90" aria-hidden="true">
            <circle cx="50" cy="50" r="44" fill="none" stroke-width="7" class="stroke-muted" />
            <circle
              :for={r <- @rows}
              :if={r.count > 0}
              cx="50"
              cy="50"
              r="44"
              pathLength="100"
              fill="none"
              stroke="currentColor"
              stroke-width="7"
              stroke-dasharray={"#{r.share} 100"}
              stroke-dashoffset={r.offset}
              class={r.color}
            />
          </svg>
          <div class="text-center">
            <p class="text-xl font-semibold tabular-nums text-ink">{percent(@rate)}</p><p class="text-[10px] text-ink-2">
              succeeded
            </p>
          </div>
        </div>
        <dl class="grid min-w-32 flex-1 gap-x-6 gap-y-1 text-xs xl:w-full xl:grid-cols-2">
          <div :for={r <- @rows} class="flex items-center justify-between gap-1.5">
            <dt class="flex items-center gap-1.5 text-ink-2">
              <span class={["size-1.5 shrink-0 rounded-full bg-current", r.color]}></span>{r.label}
            </dt>
            <dd class="font-medium tabular-nums text-ink">{UsageComponents.delimit(r.count)}</dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  defp started_series(s) do
    [success, failure, other] = Geometry.stack([s.success, s.failure, s.other])

    for {label, color, points} <- [
          {"Succeeded", Charts.accent_color(), success},
          {"Failed", Charts.series_color(7), failure},
          {"Other", Charts.other_color(), other}
        ] do
      total = Enum.sum_by(points, fn {_t, low, high} -> high - low end)

      %{
        label: label,
        color: color,
        kind: :bar,
        interval: s.interval,
        points: points,
        total: total,
        value: UsageComponents.delimit(total)
      }
    end
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
