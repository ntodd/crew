defmodule CrewWeb.QueueLive do
  @moduledoc """
  The queue (§17.3): waiting units in placement order (§8.4) with their
  class, wait and reason; each class's demand, supply and deficit, and
  whether it's stalled or backing off; and six hours of queue depth and
  booting VMs. Admins change a repo's priority here. Members see jobs of
  repos they can't read as "a job in another repo" (§18.3).

  It refreshes every 2 s while open: the view is one scheduling pass's,
  without placing anything.
  """
  use CrewWeb, :live_view

  alias Crew.{Jobs, Repos, Scheduler, Scope}
  alias CrewWeb.{Charts, JobStatus}

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, socket |> assign(:page_title, "Queue") |> load()}
  end

  defp load(socket) do
    view = Scheduler.queue_view()

    assign(socket,
      queue: view.queue,
      jobs: view.jobs,
      repos: view.repos,
      readable: Repos.readable_ids(socket.assigns.current_scope),
      series: Jobs.queue_series(),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("priority", %{"repo_id" => id, "priority" => value}, socket) do
    with %{} = repo <- Repos.get(id),
         {n, ""} <- Integer.parse(value),
         {:ok, _} <- Repos.update_settings(socket.assigns.current_scope, repo, %{"priority" => n}) do
      {:noreply, socket |> put_flash(:info, "#{repo.full_name}'s priority is #{n}.") |> load()}
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Only admins can do that.")}
      _ -> {:noreply, put_flash(socket, :error, "That priority wasn't saved.")}
    end
  end

  defp readable?(:all, _repo_id), do: true
  defp readable?(ids, repo_id), do: repo_id in ids

  defp repo_label(assigns, repo_id) do
    if readable?(assigns.readable, repo_id),
      do: (assigns.repos[repo_id] && assigns.repos[repo_id].full_name) || "–",
      else: "another repo"
  end

  defp wait(job, now), do: JobStatus.format(JobStatus.duration(job.queued_at || job.seen_at, now))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Queue</:breadcrumb>

      <.header>
        Queue
        <:subtitle>
          Waiting jobs in the order Crew would place them, and each class's supply.
        </:subtitle>
      </.header>

      <div class="grid gap-4 xl:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <.panel id="units" title="Waiting" padded={false}>
          <:subtitle>
            {length(@queue.units)} waiting · {length(@queue.covered)} with a runner on its way
          </:subtitle>
          <ol class="divide-y divide-line text-sm">
            <li
              :for={{unit, i} <- Enum.with_index(@queue.units, 1)}
              :if={job = @jobs[unit.job_id]}
              id={"unit-#{unit.job_id}"}
              class="grid grid-cols-[2rem_minmax(0,1fr)_auto] items-baseline gap-x-3 gap-y-0.5 px-5 py-2.5"
            >
              <span class="tabular-nums text-ink-3">{i}</span>
              <span class="min-w-0">
                <%= if readable?(@readable, job.repo_id) do %>
                  <span class="block truncate text-ink">{job.name}</span>
                  <span class="block truncate text-xs text-ink-3">
                    {repo_label(assigns, job.repo_id)} ·
                    <span class="font-mono">{Enum.join(job.label_key || [], ", ")}</span>
                  </span>
                <% else %>
                  <span class="block truncate text-ink-2">a job in another repo</span>
                  <span class="block text-xs text-ink-3">{job.size && job.size.name}</span>
                <% end %>
                <span :if={unit.wait_reason || unit.blocked_reason} class="block text-xs text-warning">
                  {unit.blocked_reason || unit.wait_reason}
                </span>
                <span :if={unit.placed} class="block text-xs text-success">placing now</span>
              </span>
              <span class="tabular-nums text-xs text-ink-3">{wait(job, @now)}</span>
            </li>
            <li
              :for={{id, reason} <- @queue.blocked}
              :if={job = @jobs[id]}
              id={"blocked-#{id}"}
              class="grid grid-cols-[2rem_minmax(0,1fr)_auto] items-baseline gap-x-3 px-5 py-2.5"
            >
              <.icon name="hero-pause-circle" class="size-4 text-warning" />
              <span class="min-w-0">
                <%= if readable?(@readable, job.repo_id) do %>
                  <span class="block truncate text-ink">{job.name}</span>
                  <span class="block truncate text-xs text-ink-3">
                    {repo_label(assigns, job.repo_id)} ·
                    <span class="font-mono">{Enum.join(job.label_key || [], ", ")}</span>
                  </span>
                <% else %>
                  <span class="block truncate text-ink-2">a job in another repo</span>
                <% end %>
                <span class="block text-xs text-warning">Blocked: {reason}</span>
              </span>
              <span class="tabular-nums text-xs text-ink-3">{wait(job, @now)}</span>
            </li>
            <li :if={@queue.units == [] and @queue.blocked == []} class="px-5 py-4 text-ink-3">
              Nothing is waiting.
            </li>
          </ol>
        </.panel>

        <div class="space-y-4">
          <.panel id="classes" title="Classes" padded={false}>
            <:subtitle>
              Demand is waiting jobs; supply is VMs booting or idle for the class.
            </:subtitle>
            <table class="w-full text-sm">
              <thead class="text-left text-xs text-ink-3">
                <tr>
                  <th class="px-5 py-2 font-medium">Class</th>
                  <th class="px-2 py-2 text-right font-medium">Demand</th>
                  <th class="px-2 py-2 text-right font-medium">Supply</th>
                  <th class="px-5 py-2 text-right font-medium">Deficit</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-line">
                <tr
                  :for={
                    {{repo_id, key} = class, c} <-
                      Enum.sort_by(@queue.classes, fn {_, c} -> -c.deficit end)
                  }
                  id={"class-#{repo_id}-#{Enum.join(key, "-")}"}
                >
                  <td class="px-5 py-2">
                    <span class="block truncate text-ink">{repo_label(assigns, repo_id)}</span>
                    <span class="font-mono text-xs text-ink-3">{Enum.join(key, ", ")}</span>
                    <span :if={c.blocked > 0} class="block text-xs text-ink-3">
                      {c.blocked} blocked
                    </span>
                    <span :if={c.stalled} class="block text-xs text-warning">Stalled: GitHub isn't assigning these runners</span>
                    <span :if={c.backoff} class="block text-xs text-danger">Backing off: {c.last_error}</span>
                  </td>
                  <td class="px-2 py-2 text-right tabular-nums">{c.demand}</td>
                  <td class="px-2 py-2 text-right tabular-nums">{c.supply}</td>
                  <td class="px-5 py-2 text-right tabular-nums">{c.deficit}</td>
                  <% _ = class %>
                </tr>
                <tr :if={@queue.classes == %{}}>
                  <td colspan="4" class="px-5 py-3 text-ink-3">No demand.</td>
                </tr>
              </tbody>
            </table>
          </.panel>

          <.panel
            :if={Scope.admin?(@current_scope) and waiting_repos(@queue, @jobs) != []}
            id="priorities"
            title="Priority"
          >
            <:subtitle>Higher goes first (§8.4). Changes are audited.</:subtitle>
            <ul class="space-y-2 text-sm">
              <li :for={repo_id <- waiting_repos(@queue, @jobs)} :if={repo = @repos[repo_id]}>
                <.form
                  for={%{}}
                  id={"priority-#{repo.id}"}
                  phx-submit="priority"
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="repo_id" value={repo.id} />
                  <label for={"priority-input-#{repo.id}"} class="min-w-0 flex-1 truncate text-ink">{repo.full_name}</label>
                  <input
                    id={"priority-input-#{repo.id}"}
                    type="number"
                    name="priority"
                    value={repo.priority}
                    min="-100"
                    max="100"
                    class="w-20 rounded-md border border-line bg-raised px-2 py-1 text-right tabular-nums"
                  />
                  <.button size="sm" type="submit">Set</.button>
                </.form>
              </li>
            </ul>
          </.panel>
        </div>
      </div>

      <div class="mt-4">
        <Charts.timeseries
          id="queue-chart"
          title="Queue depth and booting VMs, 6 hours"
          series={[
            %{label: "Waiting", color: Charts.series_color(0), kind: :line, points: @series.depth},
            %{label: "Booting", color: Charts.series_color(1), kind: :line, points: @series.booting}
          ]}
          since={@series.since}
          until={@series.until}
          ymax={
            CrewWeb.Charts.Geometry.nice_max(
              Enum.max(Enum.map(@series.depth ++ @series.booting, &elem(&1, 1)), fn -> 1 end)
            )
          }
          gap={600}
          format={&to_string(round(&1))}
          empty="Nothing has queued in the last 6 hours."
        />
      </div>
    </Layouts.app>
    """
  end

  defp waiting_repos(queue, jobs) do
    (Enum.map(queue.units, & &1.job_id) ++ Enum.map(queue.blocked, &elem(&1, 0)))
    |> Enum.map(&(jobs[&1] && jobs[&1].repo_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
