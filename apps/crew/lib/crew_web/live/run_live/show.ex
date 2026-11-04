defmodule CrewWeb.RunLive.Show do
  @moduledoc """
  A run attempt (§17.3): its header (workflow, attempt, trigger, branch
  or PR, SHA and commit message, actor, duration), its actions (Cancel
  run, Re-run failed jobs, Re-run all: `can_push`, audited), and its
  jobs grouped by matrix prefix with size, box, wait, boot and run times
  and peak memory against the size.
  """
  use CrewWeb, :live_view

  alias Crew.{Boxes, Jobs, Repos, Sizes, VMs}
  alias CrewWeb.JobStatus

  @flush_ms 250

  @impl true
  def mount(%{"run_id" => run_id, "n" => n}, _session, socket) do
    {run_id, ""} = Integer.parse(run_id)
    {n, ""} = Integer.parse(n)
    attempt = Jobs.get_run_attempt!(socket.assigns.current_scope, run_id, n)

    if connected?(socket), do: Phoenix.PubSub.subscribe(Crew.PubSub, "run:#{attempt.id}")

    {:ok,
     socket
     |> assign(:page_title, "#{attempt.workflow_name} ##{attempt.run_number}")
     |> assign(:flush_pending, false)
     |> assign(:now, DateTime.utc_now())
     |> assign(:pending_action, nil)
     |> load(attempt)}
  end

  defp load(socket, attempt) do
    vms =
      attempt.jobs
      |> Enum.map(& &1.vm_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&VMs.get/1)
      |> Enum.reject(&is_nil/1)

    boxes = vms |> Enum.map(& &1.box_id) |> Enum.uniq() |> Map.new(&{&1, Boxes.get(&1)})

    assign(socket,
      attempt: attempt,
      vms: Map.new(vms, &{&1.id, &1}),
      boxes: boxes,
      sizes: Map.new(Sizes.list(), &{&1.id, &1}),
      can_push: Repos.can_push?(socket.assigns.current_scope, attempt.repo_id)
    )
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

  def handle_info(:flush, socket) do
    a = socket.assigns.attempt
    attempt = Jobs.get_run_attempt!(socket.assigns.current_scope, a.github_run_id, a.run_attempt)
    {:noreply, socket |> load(attempt) |> assign(flush_pending: false, now: DateTime.utc_now())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event(action, _params, socket) when action in ["cancel", "rerun", "rerun_failed"] do
    action = String.to_existing_atom(action)

    case Jobs.run_action(socket.assigns.current_scope, socket.assigns.attempt, action) do
      :ok ->
        {:noreply,
         socket |> assign(pending_action: action) |> put_flash(:info, action_note(action))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "That needs push access to the repo.")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "GitHub didn't take it: #{inspect(reason) |> String.slice(0, 120)}"
         )}
    end
  end

  defp action_note(:cancel), do: "Cancelling the run…"
  defp action_note(:rerun), do: "Re-running every job…"
  defp action_note(:rerun_failed), do: "Re-running the failed jobs…"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb navigate={~p"/runs"}>Runs</:breadcrumb>
      <:breadcrumb>{@attempt.workflow_name} #{@attempt.run_number}</:breadcrumb>

      <.header>
        {@attempt.workflow_name} <span class="text-ink-3">#{@attempt.run_number}</span>
        <:subtitle>
          {@attempt.repo.full_name} · attempt {@attempt.run_attempt} · {@attempt.event}
        </:subtitle>
        <:actions>
          <.button
            :if={@can_push and @attempt.status != "completed"}
            id="cancel-run"
            size="sm"
            variant="danger_outline"
            phx-click="cancel"
            data-confirm="Cancel this run on GitHub?"
            disabled={@pending_action == :cancel}
          >
            {if @pending_action == :cancel, do: "Cancelling…", else: "Cancel run"}
          </.button>
          <.button
            :if={
              @can_push and @attempt.status == "completed" and
                Enum.any?(@attempt.jobs, &(&1.conclusion in ["failure", "cancelled"]))
            }
            id="rerun-failed"
            size="sm"
            phx-click="rerun_failed"
          >
            Re-run failed jobs
          </.button>
          <.button
            :if={@can_push and @attempt.status == "completed"}
            id="rerun-all"
            size="sm"
            phx-click="rerun"
          >
            Re-run all
          </.button>
          <.button
            href={"https://github.com/#{@attempt.repo.full_name}/actions/runs/#{@attempt.github_run_id}/attempts/#{@attempt.run_attempt}"}
            target="_blank"
            rel="noopener"
            size="sm"
            icon="hero-arrow-top-right-on-square"
          >
            Open on GitHub
          </.button>
        </:actions>
      </.header>

      <.panel id="run-header">
        <dl class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <dt class="text-xs text-ink-3">Branch</dt>
            <dd class="mt-0.5 text-ink">
              {@attempt.head_branch}
              <span :for={pr <- @attempt.pull_requests} class="text-ink-2"> · PR #{pr["number"]}</span>
            </dd>
          </div>
          <div>
            <dt class="text-xs text-ink-3">Commit</dt>
            <dd class="mt-0.5 truncate text-ink">
              <span class="font-mono">{String.slice(@attempt.head_sha || "", 0, 7)}</span>
              <span id="commit-message" class="text-ink-2">{first_line(@attempt.head_commit_message)}</span>
            </dd>
          </div>
          <div>
            <dt class="text-xs text-ink-3">Actor</dt>
            <dd class="mt-0.5 text-ink">{@attempt.actor_login}</dd>
          </div>
          <div>
            <dt class="text-xs text-ink-3">Duration</dt>
            <dd class="mt-0.5 tabular-nums text-ink">{JobStatus.format(duration(@attempt, @now))}</dd>
          </div>
        </dl>
        <p :if={@attempt.run_attempt > 1} class="mt-3 text-xs text-ink-3">
          Earlier attempts:
          <.link
            :for={n <- @attempt.earlier_attempts}
            navigate={~p"/runs/#{@attempt.github_run_id}/attempts/#{n}"}
            class="ml-1 underline"
          >#{n}</.link>
        </p>
      </.panel>

      <.panel id="run-jobs" title="Jobs" padded={false}>
        <div class="overflow-x-auto">
          <table class="w-full min-w-[44rem] text-sm">
            <thead class="text-left text-xs text-ink-3">
              <tr>
                <th class="px-5 py-2 font-medium">Job</th>
                <th class="px-2 py-2 font-medium">State</th>
                <th class="px-2 py-2 font-medium">Size</th>
                <th class="px-2 py-2 font-medium">Box</th>
                <th class="px-2 py-2 text-right font-medium">Wait</th>
                <th class="px-2 py-2 text-right font-medium">Boot</th>
                <th class="px-2 py-2 text-right font-medium">Run</th>
                <th class="px-5 py-2 text-right font-medium">Peak memory</th>
              </tr>
            </thead>
            <tbody
              :for={{prefix, jobs} <- groups(@attempt.jobs)}
              id={"group-#{slug(prefix)}"}
              class="border-t border-line"
            >
              <tr :if={length(jobs) > 1} class="bg-subtle">
                <td colspan="8" class="px-5 py-1.5 text-xs font-medium text-ink-2">
                  {prefix} · {length(jobs)} jobs
                </td>
              </tr>
              <tr
                :for={job <- jobs}
                id={"job-#{job.github_id}"}
                class="border-t border-line first:border-t-0"
              >
                <% vm = job.vm_id && @vms[job.vm_id] %>
                <td class="max-w-0 px-5 py-2.5">
                  <.link
                    navigate={
                      ~p"/runs/#{@attempt.github_run_id}/attempts/#{@attempt.run_attempt}/jobs/#{job.github_id}"
                    }
                    class="block truncate font-medium text-ink underline-offset-2 hover:underline"
                  >
                    {job.name}
                  </.link>
                  <span class="block truncate font-mono text-xs text-ink-3">{Enum.join(
                    job.label_key || job.labels,
                    ", "
                  )}</span>
                </td>
                <td class="px-2 py-2.5"><.job_status job={job} now={@now} /></td>
                <td data-col="size" class="px-2 py-2.5 text-ink-2">
                  {job.size_id && @sizes[job.size_id] && @sizes[job.size_id].name}
                </td>
                <td data-col="box" class="px-2 py-2.5 text-ink-2">
                  {vm && @boxes[vm.box_id] && @boxes[vm.box_id].name}
                </td>
                <td class="px-2 py-2.5 text-right tabular-nums text-ink-3">
                  {JobStatus.format(
                    JobStatus.duration(job.seen_at, (vm && vm.requested_at) || job.started_at)
                  )}
                </td>
                <td class="px-2 py-2.5 text-right tabular-nums text-ink-3">
                  {JobStatus.format(
                    vm && JobStatus.duration(vm.requested_at, vm.idle_at || vm.busy_at)
                  )}
                </td>
                <td class="px-2 py-2.5 text-right tabular-nums text-ink-3">
                  {JobStatus.format(
                    JobStatus.duration(
                      job.started_at,
                      job.completed_at || (job.gh_state == "in_progress" && @now) || nil
                    )
                  )}
                </td>
                <td class="px-5 py-2.5 text-right tabular-nums text-ink-3">
                  <span :if={job.peak_mem_mib && vm}>{gib(job.peak_mem_mib)} / {gib(vm.memory_mib)} GiB</span>
                  <span :if={!(job.peak_mem_mib && vm)}>–</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>
    </Layouts.app>
    """
  end

  # Matrix jobs, "test (1)" and "test (2)", group under "test"; each
  # group in the order its first job started.
  defp groups(jobs) do
    jobs
    |> Enum.group_by(&prefix(&1.name || ""))
    |> Enum.sort_by(fn {_, js} -> js |> Enum.map(&sort_time/1) |> Enum.min() end)
    |> Enum.map(fn {prefix, js} -> {prefix, Enum.sort_by(js, &sort_time/1)} end)
  end

  defp sort_time(job),
    do:
      {(job.started_at && DateTime.to_unix(job.started_at, :microsecond)) || 9_999_999_999_999_999,
       job.github_id}

  defp prefix(name), do: name |> String.split(" (", parts: 2) |> hd()

  defp slug(prefix),
    do: prefix |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  defp first_line(nil), do: ""
  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  defp duration(%{status: "completed", gh_created_at: from, gh_updated_at: to}, _now),
    do: JobStatus.duration(from, to)

  defp duration(%{gh_created_at: from}, now), do: JobStatus.duration(from, now)
end
