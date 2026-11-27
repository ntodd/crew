defmodule CrewWeb.UsageLive do
  @moduledoc """
  Usage across the fleet (§16.6, §17.3): job minutes, VM minutes and
  their overhead, and the memory and vCPUs reserved, over the last 7, 30
  or 90 UTC days (`?days=`), by day, box, repo and size. Members see
  every box and the fleet in full, and the repos they can't read as one
  "Other repos" row.

  Today is counted live; it refreshes every minute.
  """
  use CrewWeb, :live_view

  alias Crew.Usage
  alias CrewWeb.Charts
  alias CrewWeb.UsageComponents, as: U

  @ranges [7, 30, 90]
  @default 30
  @refresh_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, assign(socket, :page_title, "Usage")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    days =
      case Integer.parse(params["days"] || "") do
        {n, ""} when n in @ranges -> n
        _ -> @default
      end

    {:noreply, socket |> assign(:days, days) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    today = Date.utc_today()
    from = Date.add(today, 1 - socket.assigns.days)
    assign(socket, :summary, Usage.summary(socket.assigns.current_scope, from, today))
  end

  defp box_name(%{box: nil}), do: "No VM"
  defp box_name(%{box: %{revoked_at: nil} = box}), do: box.name
  defp box_name(%{box: box}), do: "#{box.name} (revoked)"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :ranges, @ranges)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
      content_class="card-grid grid-cols-1"
    >
      <:breadcrumb>Usage</:breadcrumb>

      <.header class="pb-0!">
        Usage
        <:subtitle>
          Job and VM minutes over the last {@days} days. Days are UTC.
        </:subtitle>
        <:actions>
          <span class="segmented" role="group" aria-label="Days">
            <.link
              :for={n <- @ranges}
              id={"range-#{n}"}
              patch={~p"/usage?days=#{n}"}
              aria-current={to_string(n == @days)}
            >
              {n}d
            </.link>
          </span>
        </:actions>
      </.header>

      <p :if={U.pending(@summary.pending)} id="usage-pending" class="text-xs text-ink-3">
        {U.pending(@summary.pending)}
      </p>

      <.panel :if={U.empty?(@summary)} id="usage-empty" title="Nothing yet">
        <p class="text-sm text-ink-3">
          No Crew jobs or VMs in the last {@days} days.
        </p>
      </.panel>

      <div :if={not U.empty?(@summary)} class="@container card-grid grid-cols-1">
        <section
          id="usage-totals"
          aria-label="Usage totals"
          class="card-grid grid-cols-2 @4xl:grid-cols-4"
        >
          <.stat_card value_id="usage-job-minutes" label="Job minutes" icon="hero-clock">
            {U.minutes(@summary.totals.job_s)}
            <:note>
              {U.delimit(@summary.totals.job_billable_min)} rounded up per job, as GitHub bills
            </:note>
          </.stat_card>
          <.stat_card value_id="usage-vm-minutes" label="VM minutes" icon="hero-cube">
            {U.minutes(@summary.totals.vm_s)}
            <:note>
              {U.delimit(@summary.totals.vm_count)} {if @summary.totals.vm_count == 1,
                do: "VM",
                else: "VMs"}, {U.delimit(@summary.totals.unused_count)} never used
            </:note>
          </.stat_card>
          <.stat_card value_id="usage-overhead" label="Overhead" icon="hero-adjustments-horizontal">
            {U.overhead(@summary.totals)}
            <:note>Boot, idle and teardown time</:note>
          </.stat_card>
          <.stat_card
            value_id="usage-reserved"
            label="Reserved GiB-hours"
            icon="hero-square-3-stack-3d"
          >
            {U.gib_h(@summary.totals.mem_mib_s)}
            <:note>{U.vcpu_h(@summary.totals.vcpu_s)} vCPU-hours reserved</:note>
          </.stat_card>
        </section>

        <.github_spend estimate={@summary.github_spend} />

        <div class="card-grid grid-cols-1 @4xl:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
          <U.chart id="usage-chart" summary={@summary} />
          <.panel id="usage-phases" title="VM time by phase">
            <:subtitle>Share of VM minutes over the selected period</:subtitle>
            <ul class="space-y-4">
              <li :for={
                {label, seconds, color} <- [
                  {"Busy", @summary.totals.busy_s, Charts.series_color(0)},
                  {"Idle", @summary.totals.idle_s, Charts.series_color(3)},
                  {"Boot", @summary.totals.boot_s, Charts.series_color(1)},
                  {"Teardown", @summary.totals.teardown_s, Charts.other_color()}
                ]
              }>
                <div class="flex justify-between gap-2 text-xs">
                  <span class="font-medium text-ink">{label}</span>
                  <span class="tabular-nums text-ink-2">{U.minutes(seconds)} min · {U.share(
                    seconds,
                    @summary.totals.vm_s
                  )}</span>
                </div>
                <progress
                  aria-label={label}
                  value={seconds}
                  max={max(@summary.totals.vm_s, 1)}
                  class={["bar phase-bar mt-2", color]}
                ></progress>
              </li>
            </ul>
          </.panel>
        </div>

        <.panel id="usage-boxes" title="By box">
          <:subtitle>Use is what the box's VMs reserved of what it offered while online.</:subtitle>
          <.table id="usage-box-rows" rows={@summary.boxes}>
            <:col :let={b} label="Box">
              <.link
                :if={b.box}
                navigate={~p"/boxes/#{b.box.id}"}
                class="font-medium text-ink underline-offset-2 hover:underline"
              >
                {box_name(b)}
              </.link>
              <span :if={!b.box} class="text-ink-2">{box_name(b)}</span>
            </:col>
            <:col :let={b} label="VM min" align="right" class="tabular-nums">
              {U.minutes(b.vm_s)}
            </:col>
            <:col :let={b} label="Busy" align="right" class="hidden tabular-nums sm:table-cell">
              {U.share(b.busy_s, b.vm_s)}
            </:col>
            <:col :let={b} label="Job min" align="right" class="tabular-nums">
              {U.minutes(b.job_s)}
            </:col>
            <:col :let={b} label="Memory use" align="right" class="tabular-nums">
              {U.pct(b.mem_use)}
            </:col>
            <:col :let={b} label="vCPU use" align="right" class="hidden tabular-nums sm:table-cell">
              {U.pct(b.vcpu_use)}
            </:col>
            <:col
              :let={b}
              label="Reserved GiB-h"
              align="right"
              class="hidden tabular-nums sm:table-cell"
            >
              {U.gib_h(b.mem_mib_s)}
            </:col>
          </.table>
        </.panel>

        <div class="card-grid grid-cols-1 items-start @[70rem]:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
          <.panel id="usage-repos" title="By repo">
            <.table id="usage-repo-rows" rows={@summary.repos}>
              <:col :let={r} label="Repo">
                <.link
                  :if={r.repo}
                  navigate={~p"/repos/#{r.repo.id}"}
                  class="font-medium text-ink underline-offset-2 hover:underline"
                >
                  {r.repo.full_name}
                </.link>
                <span :if={!r.repo} class="text-ink-2">Other repos</span>
              </:col>
              <:col :let={r} label="Jobs" align="right" class="hidden tabular-nums sm:table-cell">
                {U.delimit(r.job_count)}
              </:col>
              <:col :let={r} label="Job min" align="right" class="tabular-nums">
                {U.minutes(r.job_s)}
              </:col>
              <:col
                :let={r}
                label="Rounded up"
                align="right"
                class="hidden tabular-nums sm:table-cell"
              >
                {U.delimit(r.job_billable_min)}
              </:col>
              <:col :let={r} label="VM min" align="right" class="tabular-nums">
                {U.minutes(r.vm_s)}
              </:col>
              <:col :let={r} label="Overhead" align="right" class="hidden tabular-nums sm:table-cell">
                {U.overhead(r)}
              </:col>
            </.table>
          </.panel>

          <.panel id="usage-sizes" title="By size">
            <.table id="usage-size-rows" rows={@summary.shapes}>
              <:col :let={s} label="Size">{U.shape(s.shape)}</:col>
              <:col :let={s} label="Jobs" align="right" class="hidden tabular-nums sm:table-cell">
                {U.delimit(s.job_count)}
              </:col>
              <:col :let={s} label="Job min" align="right" class="tabular-nums">
                {U.minutes(s.job_s)}
              </:col>
              <:col :let={s} label="VM min" align="right" class="tabular-nums">
                {U.minutes(s.vm_s)}
              </:col>
            </.table>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :estimate, :map, required: true

  defp github_spend(assigns) do
    ~H"""
    <details
      id="usage-github-spend"
      phx-mounted={JS.ignore_attributes(["open"])}
      class="group rounded-xl border border-line bg-raised shadow-xs"
    >
      <summary class="flex cursor-pointer list-none items-center gap-3 px-5 py-4 [&::-webkit-details-marker]:hidden">
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-semibold text-ink">GitHub Actions equivalent spend</span>
          <span class="block text-xs text-ink-2">Estimated runner cost in USD before plan allowances</span>
          <span :if={@estimate.unmatched_minutes > 0} class="mt-1 block text-xs text-ink-2">
            {U.delimit(@estimate.unmatched_minutes)} job {if @estimate.unmatched_minutes == 1,
              do: "minute",
              else: "minutes"} excluded without a matching runner
          </span>
        </span>
        <span id="usage-github-amount" class="text-xl font-semibold tabular-nums text-ink">
          {if @estimate.runners == [] and @estimate.unmatched_minutes > 0,
            do: "Unavailable",
            else: U.usd(@estimate.mills)}
        </span>
        <.icon
          name="hero-chevron-down-micro"
          class="size-4 shrink-0 text-ink-3 group-open:rotate-180"
        />
      </summary>
      <div class="space-y-3 border-t border-line px-5 py-4">
        <p class="text-sm text-ink-2">
          Crew rounds each finished job’s runtime up to a whole minute and prices it on the smallest
          Linux VM that matches its CPU architecture and has enough vCPUs and memory.
          Standard VMs are free for public repos. The estimate uses each box’s current guest
          architecture and each repo’s current visibility. It excludes storage charges.
          <.gh_link
            href="https://docs.github.com/en/billing/reference/actions-runner-pricing"
            class="text-accent-ink underline"
          >GitHub rates as of {Calendar.strftime(@estimate.rates_as_of, "%b %-d, %Y")}</.gh_link>
        </p>
        <.table :if={@estimate.runners != []} id="usage-github-runners" rows={@estimate.runners}>
          <:col :let={r} label="Linux VM">{r.cores}-core {r.arch}</:col>
          <:col :let={r} label="Job min" align="right" class="tabular-nums">
            {U.delimit(r.minutes)}
          </:col>
          <:col :let={r} label="USD/min" align="right" class="tabular-nums">
            {if r.rate_mills == 0, do: "Free", else: U.usd(r.rate_mills, 3)}
          </:col>
          <:col :let={r} label="Est. cost" align="right" class="tabular-nums">
            {U.usd(r.mills)}
          </:col>
        </.table>
      </div>
    </details>
    """
  end
end
