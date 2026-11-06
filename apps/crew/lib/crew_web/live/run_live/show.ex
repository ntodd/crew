defmodule CrewWeb.RunLive.Show do
  @moduledoc """
  A run attempt (§17.3), the page to watch a run on. Its header: the
  workflow and its status, a menu of the run's attempts, the repo,
  branch, PR and commit (out to GitHub), the actor, the duration and the
  jobs at a glance. Its actions: Cancel run, Re-run failed jobs, Re-run
  all (`can_push`, audited). Its jobs, grouped by matrix prefix, each
  with its progress through its steps, size, the box it ran on (with the
  box's card on hover), wait, boot and run times and peak memory against
  the size.

  It stays live. Changes arrive over PubSub, coalesced and flushed at
  most every 250 ms, and while the run is going the rest (the guest's
  steps, the boxes, the VMs) reloads every 5 s. Running times count up
  every second in the browser (the Clock hook, from each `data-from`), so
  the clock costs the server nothing. Once the run is done the page
  reloads every 30 s, for a new attempt or late figures.
  """
  use CrewWeb, :live_view

  alias Crew.{Boxes, Jobs, Logs, Repos, Sizes, VMs}
  alias CrewWeb.{BoxCard, JobStatus, JobSteps}

  import CrewWeb.GitHub

  @flush_ms 250
  @live_ms 5_000
  @idle_ms 30_000

  @impl true
  def mount(%{"run_id" => run_id, "n" => n}, _session, socket) do
    {run_id, ""} = Integer.parse(run_id)
    {n, ""} = Integer.parse(n)
    attempt = Jobs.get_run_attempt!(socket.assigns.current_scope, run_id, n)

    socket =
      socket
      |> assign(:page_title, "#{attempt.workflow_name} ##{attempt.run_number}")
      |> assign(:flush_pending, false)
      |> assign(:now, DateTime.utc_now())
      |> assign(:pending_action, nil)
      |> load(attempt)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Crew.PubSub, "run:#{attempt.id}")
      schedule_refresh(socket)
    end

    {:ok, socket}
  end

  # Everything: the attempt and its jobs (`load_jobs/2`), and what's
  # slower to gather and changes less, the attempts and the box cards.
  defp load(socket, attempt) do
    # The boxes afresh too: a flush reuses them, a reload shouldn't.
    socket = socket |> assign(:boxes, %{}) |> load_jobs(attempt)
    boxes = socket.assigns.boxes

    assign(socket,
      attempts: Jobs.list_attempts(socket.assigns.current_scope, attempt.github_run_id),
      box_cards: for({id, box} <- boxes, box, do: {id, BoxCard.load(box)})
    )
  end

  # The attempt, its jobs, their VMs and boxes, and their steps: what a
  # job or run change moves.
  defp load_jobs(socket, attempt) do
    vms =
      attempt.jobs
      |> Enum.map(& &1.vm_id)
      |> Enum.reject(&is_nil/1)
      |> VMs.get_many()
      |> Map.new(&{&1.id, &1})

    box_ids = vms |> Map.values() |> Enum.map(& &1.box_id) |> Enum.uniq()
    known = socket.assigns[:boxes] || %{}

    boxes =
      if Enum.all?(box_ids, &Map.has_key?(known, &1)),
        do: Map.take(known, box_ids),
        else: Map.new(box_ids, &{&1, Boxes.get(&1)})

    assign(socket,
      attempt: attempt,
      vms: vms,
      boxes: boxes,
      steps: Map.new(attempt.jobs, &{&1.id, JobSteps.of(&1, guest_steps(&1, vms))}),
      sizes: socket.assigns[:sizes] || Map.new(Sizes.list(), &{&1.id, &1}),
      can_push: Repos.can_push?(socket.assigns.current_scope, attempt.repo_id)
    )
  end

  # The guest's steps, read only where they're the ones shown: a running
  # job's, or a job GitHub gave none for.
  defp guest_steps(%{vm_id: nil}, _vms), do: []

  defp guest_steps(%{vm_id: id} = job, vms) do
    if vms[id] && (job.gh_state == "in_progress" or job.steps in [nil, []]),
      do: Logs.steps(id),
      else: []
  end

  defp fetch_attempt(socket) do
    a = socket.assigns.attempt
    Jobs.get_run_attempt!(socket.assigns.current_scope, a.github_run_id, a.run_attempt)
  end

  # Going: the attempt isn't done, or a job of it isn't.
  defp live?(attempt),
    do: attempt.status != "completed" or Enum.any?(attempt.jobs, &(&1.gh_state != "completed"))

  defp schedule_refresh(socket) do
    ms = if live?(socket.assigns.attempt), do: @live_ms, else: @idle_ms
    Process.send_after(self(), :refresh, ms)
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
    socket = load_jobs(socket, fetch_attempt(socket))
    {:noreply, assign(socket, flush_pending: false, now: DateTime.utc_now())}
  end

  def handle_info(:refresh, socket) do
    socket = socket |> load(fetch_attempt(socket)) |> assign(now: DateTime.utc_now())
    schedule_refresh(socket)
    {:noreply, socket}
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
      <:breadcrumb navigate={~p"/runs"}>Runs</:breadcrumb>
      <:breadcrumb>{@attempt.workflow_name} #{@attempt.run_number}</:breadcrumb>

      <div id="run-page" phx-hook="Clock" data-now={DateTime.to_iso8601(@now)} class="space-y-6">
        <.header class="pb-0">
          <span class="flex items-center gap-2.5">
            <.run_status_icon id="run-status" run={@attempt} class="size-6" />
            <span>
              {@attempt.workflow_name} <span class="text-ink-3">#{@attempt.run_number}</span>
            </span>
          </span>
          <:subtitle>
            <div class="flex flex-wrap items-center gap-x-1.5 gap-y-1">
              <.gh_link href={repo_url(@attempt.repo)}>{@attempt.repo.full_name}</.gh_link>
              <span aria-hidden="true">·</span>
              <.attempt_menu attempt={@attempt} attempts={@attempts} now={@now} />
              <span aria-hidden="true">·</span>
              <span>{@attempt.event}</span>
              <span aria-hidden="true">·</span>
              <span>started {JobStatus.ago(@attempt.gh_created_at, @now)} ago</span>
            </div>
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
              href={run_url(@attempt)}
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
          <dl class="grid gap-x-8 gap-y-4 text-sm sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-[minmax(0,2.2fr)_minmax(0,0.6fr)_minmax(0,2fr)_minmax(0,0.7fr)_minmax(0,0.6fr)_minmax(0,1.3fr)]">
            <.summary_item term="Branch">
              <.gh_link
                :if={@attempt.head_branch}
                href={branch_url(@attempt.repo, @attempt.head_branch)}
                title={@attempt.head_branch}
                class="block truncate"
              >
                {@attempt.head_branch}
              </.gh_link>
            </.summary_item>
            <.summary_item term="Pull request">
              <span :if={@attempt.pull_requests == []} class="text-ink-3">–</span>
              <span :for={pr <- @attempt.pull_requests} class="mr-2">
                <.gh_link href={pr_url(@attempt.repo, pr["number"])}>PR #{pr["number"]}</.gh_link>
              </span>
            </.summary_item>
            <.summary_item term="Commit">
              <span class="flex min-w-0 items-baseline gap-2">
                <.gh_link
                  :if={@attempt.head_sha}
                  href={commit_url(@attempt.repo, @attempt.head_sha)}
                  class="shrink-0 font-mono"
                >
                  {String.slice(@attempt.head_sha, 0, 7)}
                </.gh_link>
                <span
                  id="commit-message"
                  class="truncate text-ink-2"
                  title={first_line(@attempt.head_commit_message)}
                >
                  {first_line(@attempt.head_commit_message)}
                </span>
              </span>
            </.summary_item>
            <.summary_item term="Actor">{@attempt.actor_login}</.summary_item>
            <.summary_item term="Duration">
              <span
                id="run-duration"
                class="tabular-nums"
                data-from={
                  @attempt.status != "completed" && DateTime.to_iso8601(@attempt.gh_created_at)
                }
              >
                {JobStatus.format(duration(@attempt, @now))}
              </span>
            </.summary_item>
            <.summary_item term="Jobs">
              <span class="flex items-center gap-3">
                <.job_bar id="run-bar" jobs={@attempt.jobs} now={@now} />
                <span class="whitespace-nowrap text-xs tabular-nums text-ink-3">
                  {Enum.count(@attempt.jobs, &(&1.gh_state == "completed"))} of {length(@attempt.jobs)} done
                </span>
              </span>
            </.summary_item>
          </dl>
        </.panel>

        <.panel id="run-jobs" title="Jobs" padded={false}>
          <div class="overflow-x-auto">
            <table class="w-full min-w-[64rem] text-sm">
              <thead class="text-left text-xs text-ink-3">
                <tr>
                  <th class="w-[18%] px-5 py-2 font-medium">Job</th>
                  <th class="w-[26%] px-3 py-2 font-medium">State</th>
                  <th class="w-[22%] px-3 py-2 font-medium">Steps</th>
                  <th class="px-2 py-2 font-medium">Size</th>
                  <th class="px-2 py-2 font-medium">Box</th>
                  <th class="px-2 py-2 text-right font-medium">Wait</th>
                  <th class="px-2 py-2 text-right font-medium">Boot</th>
                  <th class="px-2 py-2 text-right font-medium">Run</th>
                  <th class="whitespace-nowrap px-5 py-2 text-right font-medium">Peak memory</th>
                </tr>
              </thead>
              <tbody
                :for={{prefix, jobs} <- groups(@attempt.jobs)}
                :key={prefix}
                id={"group-#{slug(prefix)}"}
                class="border-t border-line"
              >
                <tr :if={length(jobs) > 1} class="bg-subtle">
                  <td colspan="9" class="px-5 py-1.5 text-xs font-medium text-ink-2">
                    {prefix} · {length(jobs)} jobs
                  </td>
                </tr>
                <tr
                  :for={job <- jobs}
                  :key={job.github_id}
                  id={"job-#{job.github_id}"}
                  class="border-t border-line first:border-t-0"
                >
                  <% vm = job.vm_id && @vms[job.vm_id] %>
                  <% box = vm && @boxes[vm.box_id] %>
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
                  <td class="max-w-0 px-3 py-2.5"><.job_status job={job} now={@now} /></td>
                  <td class="max-w-0 px-3 py-2.5"><.step_progress steps={@steps[job.id]} /></td>
                  <td data-col="size" class="whitespace-nowrap px-2 py-2.5 text-ink-2">
                    {job.size_id && @sizes[job.size_id] && @sizes[job.size_id].name}
                  </td>
                  <td data-col="box" class="whitespace-nowrap px-2 py-2.5 text-ink-2">
                    <.link
                      :if={box}
                      id={"box-link-#{job.github_id}"}
                      navigate={~p"/boxes/#{box.id}"}
                      data-card={"box-card-#{box.id}"}
                      aria-describedby={"box-summary-#{box.id}"}
                      phx-hook="HoverCard"
                      class="underline-offset-2 hover:text-ink hover:underline"
                    >
                      {box.name}
                    </.link>
                  </td>
                  <td class="whitespace-nowrap px-2 py-2.5 text-right tabular-nums text-ink-3">
                    {JobStatus.format(
                      JobStatus.duration(job.seen_at, (vm && vm.requested_at) || job.started_at)
                    )}
                  </td>
                  <td class="whitespace-nowrap px-2 py-2.5 text-right tabular-nums text-ink-3">
                    {JobStatus.format(
                      vm && JobStatus.duration(vm.requested_at, vm.idle_at || vm.busy_at)
                    )}
                  </td>
                  <td
                    data-col="run"
                    class="whitespace-nowrap px-2 py-2.5 text-right tabular-nums text-ink-3"
                  >
                    <span data-from={
                      job.gh_state == "in_progress" && job.started_at &&
                        DateTime.to_iso8601(job.started_at)
                    }>
                      {JobStatus.format(
                        JobStatus.duration(
                          job.started_at,
                          job.completed_at || (job.gh_state == "in_progress" && @now) || nil
                        )
                      )}
                    </span>
                  </td>
                  <td class="whitespace-nowrap px-5 py-2.5 text-right tabular-nums text-ink-3">
                    <span :if={job.peak_mem_mib && vm}>{gib(job.peak_mem_mib)} / {gib(vm.memory_mib)} GiB</span>
                    <span :if={!(job.peak_mem_mib && vm)}>–</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <div
          :for={{id, card} <- @box_cards}
          id={"box-card-#{id}"}
          popover="manual"
          phx-hook="HoverCardPanel"
          class="inset-auto m-0 w-80 rounded-xl border border-line bg-raised p-4 text-sm text-ink shadow-overlay"
        >
          <BoxCard.box_card card={card} />
        </div>
        <span :for={{id, card} <- @box_cards} id={"box-summary-#{id}"} hidden>
          {BoxCard.summary(card)}
        </span>
      </div>
    </Layouts.app>
    """
  end

  attr :term, :string, required: true
  slot :inner_block, required: true

  defp summary_item(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-xs text-ink-3">{@term}</dt>
      <dd class="mt-0.5 min-w-0 text-ink">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :attempt, :map, required: true
  attr :attempts, :list, required: true
  attr :now, :any, required: true

  # The run's attempts, newest first, to switch between. The menu is a
  # <details> whose `open` the browser keeps, so a reload doesn't shut it.
  defp attempt_menu(%{attempts: attempts} = assigns) when length(attempts) < 2 do
    ~H"""
    <span id="attempts">Attempt {@attempt.run_attempt}</span>
    """
  end

  defp attempt_menu(assigns) do
    ~H"""
    <details
      id="attempts"
      class="relative"
      phx-mounted={JS.ignore_attributes(["open"])}
      phx-click-away={JS.remove_attribute("open")}
      phx-window-keydown={JS.remove_attribute("open")}
      phx-key="Escape"
    >
      <summary class="-mx-1.5 inline-flex cursor-pointer list-none items-center gap-1 rounded-md px-1.5 py-0.5 font-medium text-ink transition-colors hover:bg-muted [&::-webkit-details-marker]:hidden">
        Attempt {@attempt.run_attempt}
        <span class="font-normal text-ink-3">of {length(@attempts)}</span>
        <.icon name="hero-chevron-down-micro" class="size-4 text-ink-3" />
      </summary>
      <ul class="absolute left-0 top-full z-30 mt-1 w-64 rounded-lg border border-line bg-raised p-1 shadow-overlay">
        <li :for={a <- Enum.reverse(@attempts)}>
          <.link
            navigate={~p"/runs/#{a.github_run_id}/attempts/#{a.run_attempt}"}
            aria-current={a.run_attempt == @attempt.run_attempt && "page"}
            class="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm text-ink transition-colors hover:bg-muted aria-[current=page]:bg-muted aria-[current=page]:font-medium"
          >
            <.run_status_icon run={a} />
            <span>Attempt {a.run_attempt}</span>
            <span class="ml-auto text-xs tabular-nums text-ink-3">
              {JobStatus.ago(a.gh_created_at, @now)} ago
            </span>
          </.link>
        </li>
      </ul>
    </details>
    """
  end

  attr :steps, :list, default: []

  # One segment per step, coloured by its state, with how many are done
  # and the one running (or the one that failed).
  defp step_progress(assigns) do
    assigns = assign(assigns, :progress, JobSteps.progress(assigns.steps || []))

    ~H"""
    <div data-steps class="min-w-0">
      <%= if @progress do %>
        <div class="flex items-center gap-2">
          <span
            class="flex h-1.5 min-w-0 flex-1 gap-px overflow-hidden rounded-full"
            role="img"
            aria-label={"#{@progress.done} of #{@progress.total} steps done"}
          >
            <span
              :for={step <- @steps}
              data-step-state={JobSteps.state(step)}
              title={"#{step.name}: #{JobSteps.state(step)}"}
              class={["h-full min-w-px flex-1", step_segment(JobSteps.state(step))]}
            ></span>
          </span>
          <span class="shrink-0 text-xs tabular-nums text-ink-3">
            {@progress.done}/{@progress.total}
          </span>
        </div>
        <p :if={@progress.current} class="mt-1 truncate text-xs text-ink-2" title={@progress.current}>
          {@progress.current}
        </p>
        <p :if={!@progress.current && @progress.failed} class="mt-1 truncate text-xs text-danger">
          Failed at {@progress.failed}
        </p>
      <% else %>
        <span class="text-ink-3">–</span>
      <% end %>
    </div>
    """
  end

  defp step_segment("success"), do: "bg-success"
  defp step_segment("failure"), do: "bg-danger"
  defp step_segment("running"), do: "bg-running motion-safe:animate-pulse"
  defp step_segment("cancelled"), do: "bg-ink-3/50"
  defp step_segment("skipped"), do: "bg-line-strong"
  defp step_segment("done"), do: "bg-ink-3/60"
  defp step_segment(_pending), do: "bg-line"

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
