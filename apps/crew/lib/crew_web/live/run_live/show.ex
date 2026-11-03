defmodule CrewWeb.RunLive.Show do
  @moduledoc """
  A run attempt (§17.3): its header (workflow, attempt, trigger, branch
  or PR, SHA and commit message, actor, duration) and each job with
  Crew's view of it. Cancel and re-run come with the members' actions.
  """
  use CrewWeb, :live_view

  alias Crew.Jobs
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
     |> assign(:attempt, attempt)}
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
    {:noreply, assign(socket, attempt: attempt, flush_pending: false, now: DateTime.utc_now())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
        <ul class="divide-y divide-line">
          <li
            :for={job <- @attempt.jobs}
            id={"job-#{job.github_id}"}
            class="grid gap-x-4 gap-y-1 px-5 py-3 text-sm md:grid-cols-[minmax(0,1.2fr)_minmax(0,2fr)_auto] md:items-center"
          >
            <span class="truncate font-medium text-ink">{job.name}</span>
            <.job_status job={job} now={@now} />
            <span class="font-mono text-xs text-ink-3">{Enum.join(job.label_key || job.labels, ", ")}</span>
          </li>
        </ul>
      </.panel>
    </Layouts.app>
    """
  end

  defp first_line(nil), do: ""
  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  defp duration(%{status: "completed", gh_created_at: from, gh_updated_at: to}, _now),
    do: JobStatus.duration(from, to)

  defp duration(%{gh_created_at: from}, now), do: JobStatus.duration(from, now)
end
