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
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Usage</:breadcrumb>

      <.header>
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

      <p :if={U.pending(@summary.pending)} id="usage-pending" class="mb-4 text-xs text-ink-3">
        {U.pending(@summary.pending)}
      </p>

      <.panel :if={U.empty?(@summary)} id="usage-empty" title="Nothing yet">
        <p class="text-sm text-ink-3">
          No Crew jobs or VMs in the last {@days} days.
        </p>
      </.panel>

      <div :if={not U.empty?(@summary)}>
        <section id="usage-totals" class="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
            <p class="text-xs text-ink-3">Job minutes</p>
            <p id="usage-job-minutes" class="text-2xl font-semibold tabular-nums text-ink">
              {U.minutes(@summary.totals.job_s)}
            </p>
            <p class="text-xs text-ink-3">
              {U.delimit(@summary.totals.job_billable_min)} rounded up per job, as GitHub bills
            </p>
          </div>
          <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
            <p class="text-xs text-ink-3">VM minutes</p>
            <p id="usage-vm-minutes" class="text-2xl font-semibold tabular-nums text-ink">
              {U.minutes(@summary.totals.vm_s)}
            </p>
            <p class="text-xs text-ink-3">
              {U.delimit(@summary.totals.vm_count)} {if @summary.totals.vm_count == 1,
                do: "VM",
                else: "VMs"}, {U.delimit(@summary.totals.unused_count)} never used
            </p>
          </div>
          <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
            <p class="text-xs text-ink-3">Overhead</p>
            <p id="usage-overhead" class="text-2xl font-semibold tabular-nums text-ink">
              {U.overhead(@summary.totals)}
            </p>
            <p class="text-xs text-ink-3">
              boot {U.minutes(@summary.totals.boot_s)}, idle {U.minutes(@summary.totals.idle_s)}, teardown {U.minutes(
                @summary.totals.teardown_s
              )} min
            </p>
          </div>
          <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
            <p class="text-xs text-ink-3">Reserved</p>
            <p id="usage-reserved" class="text-2xl font-semibold tabular-nums text-ink">
              {U.gib_h(@summary.totals.mem_mib_s)}
            </p>
            <p class="text-xs text-ink-3">
              GiB-hours, {U.vcpu_h(@summary.totals.vcpu_s)} vCPU-hours
            </p>
          </div>
        </section>

        <U.chart id="usage-chart" summary={@summary} class="mb-4" />

        <.panel id="usage-boxes" title="By box" class="mb-4">
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

        <.panel id="usage-repos" title="By repo" class="mb-4">
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
            <:col :let={r} label="Rounded up" align="right" class="hidden tabular-nums sm:table-cell">
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
    </Layouts.app>
    """
  end
end
