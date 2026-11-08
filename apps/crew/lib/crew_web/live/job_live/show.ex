defmodule CrewWeb.JobLive.Show do
  @moduledoc """
  The job page (§17.6): steps on the left, the timing bar on top, the log
  in the middle, and on the right the VM's charts, placement and, once
  it's done, the resource summary.

  The log viewer is `assets/js/log_viewer.js` (a hook in a
  `phx-update="ignore"` container). This side answers its range fetches
  (`lines`) and searches (`search`), pushes new lines (`append`,
  coalesced every 250 ms), and switches it to GitHub's log when that
  arrives (`source`). Every event checks access again (§18.3).
  """
  use CrewWeb, :live_view

  require Logger

  alias Crew.{Boxes, Images, Jobs, Logs, Metrics, Repos, Scope, Sizes, Sizing, VMs}
  alias CrewWeb.{JobStatus, SizingComponents}

  @flush_ms 250
  @steps_poll_ms 10_000
  @max_push 2000

  @impl true
  def mount(%{"run_id" => run_id, "n" => n, "job_id" => job_id}, _session, socket) do
    {attempt, job} =
      Jobs.get_attempt_job!(socket.assigns.current_scope, int!(run_id), int!(n), int!(job_id))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Crew.PubSub, "job:#{job.id}")
      if job.vm_id, do: Logs.subscribe(job.vm_id)
    end

    {:ok,
     socket
     |> assign(:page_title, job.name)
     |> assign(attempt: attempt, pending: [], flush: nil, reload: false, index_due: false)
     |> assign(now: DateTime.utc_now(), shown: nil, polling: false)
     |> load(job)
     |> start_polling()}
  end

  # The API's live steps while the job runs and the page is open (§16.2).
  defp start_polling(%{assigns: %{polling: false, job: %{gh_state: "in_progress"}}} = socket) do
    if connected?(socket), do: send(self(), :poll_steps)
    assign(socket, polling: connected?(socket))
  end

  defp start_polling(socket), do: socket

  defp int!(text) do
    {n, ""} = Integer.parse(text)
    n
  end

  defp load(socket, job) do
    vm = job.vm_id && VMs.get(job.vm_id)
    # GitHub's log once it's there, unless the reader picked the VM's.
    available = Enum.filter(["github", "live"], &available?(&1, job, vm))
    default = if "github" in available, do: "github", else: "live"
    source = if socket.assigns[:shown] in available, do: socket.assigns.shown, else: default

    assign(socket,
      job: job,
      vm: vm,
      box: vm && Boxes.get(vm.box_id),
      image: vm && vm.image_id && Images.get(vm.image_id),
      size: vm && Sizes.get(vm.size_id),
      source: source,
      sources: available,
      total: total(source, job, vm) || 0,
      index: index(source, job, vm),
      steps: steps(source, job, vm),
      usual: usual_durations(job),
      metrics: if(vm, do: Metrics.vm_series(vm.id), else: []),
      sizing: Sizing.for_job(job),
      durations: Sizing.durations(job),
      status: JobStatus.of(job, DateTime.utc_now())
    )
  end

  defp available?("github", job, _vm), do: job.log_source == "github"
  defp available?("live", _job, vm), do: vm != nil

  defp owner("github", job, _vm), do: job.id
  defp owner("live", _job, %{id: id}), do: id
  defp owner(_source, _job, _vm), do: nil

  defp total(source, job, vm) do
    with id when is_binary(id) <- owner(source, job, vm), do: Logs.last_n(kind(source), id)
  end

  # The viewer's source names and the log's kind.
  defp kind("github"), do: :job
  defp kind(_live), do: :vm

  defp index(source, job, vm) do
    case owner(source, job, vm) do
      nil -> Logs.Index.new()
      id -> Logs.index(kind(source), id)
    end
  end

  # The steps the page shows (JobSteps.source/2): the guest's while the
  # job runs and it has them, else the API's (names and statuses from
  # GitHub), else the guest's. Each carries the step_ref its log lines
  # use, for the current source.
  defp steps(source, job, vm) do
    guest = if vm, do: Logs.steps(vm.id), else: []
    by_number = Map.new(guest, &{&1.number, &1})

    api =
      for s <- job.steps || [], is_integer(s["number"]) do
        %{
          number: s["number"],
          name: s["name"],
          status: s["status"],
          conclusion: s["conclusion"],
          started_at: time(s["started_at"]),
          completed_at: time(s["completed_at"]),
          ref:
            if(source == "github", do: "step-#{s["number"]}", else: by_number[s["number"]][:ref])
        }
      end

    # The same choice as the run page's bar, so its #step-N links land.
    if CrewWeb.JobSteps.source(job, guest) == :api,
      do: Enum.sort_by(api, & &1.number),
      else:
        for(
          g <- Enum.sort_by(guest, & &1.number),
          do: %{g | started_at: ms(g.started_at), completed_at: ms(g.completed_at)}
        )
  end

  defp time(nil), do: nil

  defp time(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp ms(nil), do: nil

  defp ms(n) when is_integer(n) do
    case DateTime.from_unix(n, :millisecond) do
      {:ok, at} -> at
      _ -> nil
    end
  end

  # "usually X": each step's median over the last 10 successful runs of
  # the same job.
  defp usual_durations(job) do
    Jobs.recent_successes(job, 10)
    |> Enum.flat_map(fn j ->
      for s <- j.steps || [],
          d = duration(time(s["started_at"]), time(s["completed_at"])),
          do: {s["number"], d}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {number, ds} -> {number, median(ds)} end)
  end

  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))

  defp duration(%DateTime{} = a, %DateTime{} = b), do: max(0, DateTime.diff(b, a))
  defp duration(_, _), do: nil

  # -- the viewer's events --------------------------------------------------------------

  @impl true
  def handle_event("lines", %{"source" => source, "from" => from, "to" => to}, socket)
      when is_integer(from) and is_integer(to) do
    with :ok <- allowed(socket),
         id when is_binary(id) <- owner(source, socket.assigns.job, socket.assigns.vm) do
      lines = Logs.lines(kind(source), id, from, to)
      # The total too: a log retention deleted has none, and the viewer
      # shrinks to what's there rather than asking again.
      {:reply, %{lines: lines, total: Logs.last_n(kind(source), id) || 0}, socket}
    else
      {:error, message} -> {:reply, %{error: message}, socket}
      _ -> {:reply, %{lines: []}, socket}
    end
  end

  def handle_event("search", %{"source" => source, "q" => q} = params, socket)
      when is_binary(q) do
    user_id = socket.assigns.current_scope.user.id

    with :ok <- allowed(socket),
         id when is_binary(id) <- owner(source, socket.assigns.job, socket.assigns.vm),
         :ok <- one_search(user_id) do
      try do
        case Logs.search(kind(source), id, String.slice(q, 0, 500),
               regex: params["regex"] == true,
               case: params["case"] == true
             ) do
          {:ok, hits} -> {:reply, %{hits: hits}, socket}
          {:error, message} -> {:reply, %{error: message}, socket}
        end
      after
        Registry.unregister(Crew.Registry, {:log_search, user_id})
      end
    else
      {:error, message} -> {:reply, %{error: message}, socket}
      _ -> {:reply, %{hits: []}, socket}
    end
  end

  def handle_event("show_source", %{"source" => source}, socket)
      when source in ["github", "live"] do
    case allowed(socket) do
      :ok -> {:noreply, socket |> assign(shown: source) |> reload()}
      {:error, _} -> {:noreply, push_navigate(socket, to: ~p"/runs")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp allowed(socket) do
    if Repos.can_read?(socket.assigns.current_scope, socket.assigns.job.repo_id),
      do: :ok,
      else: {:error, "no access"}
  end

  # One search per user at a time, across their tabs (§17.6).
  defp one_search(user_id) do
    case Registry.register(Crew.Registry, {:log_search, user_id}, nil) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "another search is still running"}
    end
  end

  # -- live updates ---------------------------------------------------------------------

  @impl true
  def handle_info(
        {:log_lines, vm_id, lines},
        %{assigns: %{source: "live", vm: %{id: vm_id}}} = socket
      ) do
    {:noreply, socket |> assign(pending: socket.assigns.pending ++ lines) |> schedule()}
  end

  def handle_info({:log_index, vm_id}, %{assigns: %{source: "live", vm: %{id: vm_id}}} = socket) do
    {:noreply, socket |> assign(index_due: true) |> schedule()}
  end

  def handle_info({event, _id}, socket)
      when event in [:job_changed, :vm_changed, :vm_steps, :vm_metrics] do
    {:noreply, socket |> assign(reload: true) |> schedule()}
  end

  def handle_info(:flush, socket) do
    socket = assign(socket, flush: nil)

    # Access can lapse with no notice (six hours without a refresh): what
    # goes out is checked first (§18.3).
    case allowed(socket) do
      :ok ->
        socket = if socket.assigns.reload, do: reload(socket), else: socket
        {:noreply, socket |> push_pending() |> push_index()}

      {:error, _} ->
        if socket.assigns.vm, do: Logs.unsubscribe(socket.assigns.vm.id)

        {:noreply,
         socket
         |> put_flash(:error, "You no longer have access to that repo.")
         |> push_navigate(to: ~p"/runs")}
    end
  end

  def handle_info(:poll_steps, socket) do
    if socket.assigns.job.gh_state == "in_progress" do
      job = socket.assigns.job

      Task.start(fn ->
        try do
          Jobs.refresh_steps(job)
        rescue
          e -> Logger.debug("live steps for job #{job.github_id}: #{Exception.message(e)}")
        end
      end)

      Process.send_after(self(), :poll_steps, @steps_poll_ms)
      {:noreply, socket}
    else
      {:noreply, assign(socket, polling: false)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule(%{assigns: %{flush: nil}} = socket),
    do: assign(socket, flush: Process.send_after(self(), :flush, @flush_ms))

  defp schedule(socket), do: socket

  defp reload(socket) do
    before =
      {socket.assigns.source, owner(socket.assigns.source, socket.assigns.job, socket.assigns.vm)}

    job = Jobs.get_job!(socket.assigns.job.id)
    if job.vm_id && job.vm_id != socket.assigns.job.vm_id, do: Logs.subscribe(job.vm_id)

    socket =
      socket |> assign(reload: false, now: DateTime.utc_now()) |> load(job) |> start_polling()

    now =
      {socket.assigns.source, owner(socket.assigns.source, socket.assigns.job, socket.assigns.vm)}

    # A new source, or a new owner for it (the VM was linked after the
    # page opened): the viewer starts over.
    socket =
      if before != now do
        socket
        |> assign(pending: [])
        |> push_event("source", %{
          source: socket.assigns.source,
          total: socket.assigns.total,
          index: viewer_index(socket.assigns.index),
          steps: viewer_steps(socket.assigns.steps),
          running: running?(socket.assigns.job) and socket.assigns.source == "live"
        })
      else
        push_event(socket, "steps", %{
          steps: viewer_steps(socket.assigns.steps),
          running: running?(socket.assigns.job)
        })
      end

    socket
  end

  # The stream saved its index: the viewer merges it in (groups and
  # annotations from lines it never had pushed).
  defp push_index(%{assigns: %{index_due: true}} = socket) do
    index = index(socket.assigns.source, socket.assigns.job, socket.assigns.vm)

    socket
    |> assign(index_due: false, index: index)
    |> push_event("index", %{index: viewer_index(index)})
  end

  defp push_index(socket), do: socket

  # A burst bigger than the push cap goes as a new total: the viewer
  # fetches what it shows.
  defp push_pending(%{assigns: %{pending: []}} = socket), do: socket

  defp push_pending(socket) do
    lines = socket.assigns.pending
    total = List.last(lines).n
    lines = if length(lines) > @max_push, do: [], else: lines

    socket
    |> assign(pending: [], total: total)
    |> push_event("append", %{source: "live", lines: lines, total: total})
  end

  defp viewer_index(index), do: Map.take(index, [:steps, :groups, :annotations])

  defp viewer_steps(steps),
    do: Enum.map(steps, &Map.take(&1, [:number, :name, :status, :conclusion, :ref, :started_at]))

  defp running?(job), do: job.gh_state == "in_progress"

  # -- timing (§16.4) -----------------------------------------------------------------

  defp phases(job, vm, now) do
    seen = job.seen_at
    placed = vm && vm.requested_at
    listening = vm && vm.idle_at
    started = job.started_at
    done = job.completed_at || if(job.gh_state == "in_progress", do: now)

    [
      {"Waiting", duration(seen, placed || if(job.gh_state == "queued", do: now))},
      {"Boot",
       duration(placed, listening || (vm && vm.state in ~w(requested starting booted) && now))},
      {"Pickup", pickup(listening, started, job)},
      {"Run", duration(started, done)}
    ]
  end

  defp pickup(listening, started, job) do
    cond do
      job.taken_cross_class -> {:other, 0}
      listening && started && DateTime.compare(started, listening) == :lt -> {:other, 0}
      true -> duration(listening, started)
    end
  end

  defp phase_seconds({:other, s}), do: s
  defp phase_seconds(s), do: s || 0

  # -- render -----------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        phases: phases(assigns.job, assigns.vm, assigns.now),
        failed: assigns.job.conclusion == "failure"
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
      <:breadcrumb navigate={~p"/runs"}>Runs</:breadcrumb>
      <:breadcrumb navigate={~p"/runs/#{@attempt.github_run_id}/attempts/#{@attempt.run_attempt}"}>
        {@attempt.workflow_name} #{@attempt.run_number}
      </:breadcrumb>
      <:breadcrumb>{@job.name}</:breadcrumb>

      <.header>
        {@job.name}
        <:subtitle>
          {@attempt.repo.full_name} · {Enum.join(@job.labels, ", ")}
        </:subtitle>
        <:actions>
          <.job_status job={@job} now={@now} />
        </:actions>
      </.header>

      <div
        id="timing"
        phx-hook="Grow"
        class="mb-4 flex h-7 w-full overflow-hidden rounded-md border border-line text-[11px]"
      >
        <% total = max(Enum.sum_by(@phases, fn {_, s} -> phase_seconds(s) end), 1) %>
        <div
          :for={{{name, s}, i} <- Enum.with_index(@phases)}
          :if={phase_seconds(s) > 0 or match?({:other, _}, s)}
          data-phase={name}
          title={phase_title(name, s)}
          data-grow={max(phase_seconds(s), 1)}
          data-min={if phase_seconds(s) * 100 / total > 6, do: "4rem", else: "0.5rem"}
          class={["flex items-center truncate px-2", phase_class(i)]}
        >
          <span class="truncate">{name} · {JobStatus.format(phase_seconds(s))}</span>
        </div>
      </div>

      <div class="grid gap-4 xl:grid-cols-[16rem_minmax(0,1fr)_18rem]">
        <nav id="steps" aria-label="Steps" class="rounded-lg border border-line bg-raised">
          <ol class="divide-y divide-line text-sm">
            <li :for={step <- @steps} id={"step-#{step.number}"}>
              <button
                type="button"
                data-step-ref={step.ref}
                data-step-number={step.number}
                class="flex w-full items-start gap-2 px-3 py-2 text-left hover:bg-subtle data-[current=true]:bg-accent-soft"
                data-current={step.status == "in_progress"}
              >
                <.step_icon step={step} />
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-ink">{step.name}</span>
                  <span class="block text-xs text-ink-3 tabular-nums">
                    {step_duration(step, @now)}<span :if={@usual[step.number]}> · usually {JobStatus.format(
                      @usual[step.number]
                    )}</span>
                  </span>
                </span>
              </button>
            </li>
            <li :if={@steps == []} class="px-3 py-3 text-ink-3">No steps yet.</li>
          </ol>
        </nav>

        <section class="min-w-0">
          <div class="mb-2 flex items-center justify-between gap-2 text-xs text-ink-3">
            <span id="log-source" class="flex items-center gap-2">
              <span :if={length(@sources) > 1} class="segmented" role="group" aria-label="Which log">
                <a
                  id="show-github"
                  href="#"
                  phx-click="show_source"
                  phx-value-source="github"
                  aria-current={to_string(@source == "github")}
                >
                  GitHub's log
                </a>
                <a
                  id="show-live"
                  href="#"
                  phx-click="show_source"
                  phx-value-source="live"
                  aria-current={to_string(@source == "live")}
                >
                  Reported by the VM
                </a>
              </span>
              <span>
                {if @source == "github",
                  do: "GitHub's log (authoritative)",
                  else: "Reported by the VM"}
              </span>
              <span :if={@job.log_source == "live" and @job.gh_state == "completed"}>
                · GitHub's log wasn't available
              </span>
            </span>
            <.link
              id="download-raw"
              href={
                ~p"/runs/#{@attempt.github_run_id}/attempts/#{@attempt.run_attempt}/jobs/#{@job.github_id}/log.txt?source=#{@source}"
              }
              class="underline-offset-2 hover:underline"
            >
              Download raw
            </.link>
          </div>
          <div
            id="log-viewer"
            phx-hook="LogViewer"
            phx-update="ignore"
            data-source={@source}
            data-total={@total}
            data-running={to_string(running?(@job))}
            data-failed={to_string(@failed)}
            data-repo={@attempt.repo.full_name}
            data-sha={@attempt.head_sha}
            data-github={Crew.GitHub.Client.web_url()}
            data-index={Jason.encode!(viewer_index(@index))}
            data-steps={Jason.encode!(viewer_steps(@steps))}
            class="log-viewer h-[70vh] rounded-lg border border-line"
          >
          </div>
        </section>

        <aside class="space-y-4">
          <.panel :if={@vm} id="charts" title="Resources">
            <.sparkline
              id="chart-cpu"
              label="CPU"
              unit="%"
              max={100}
              values={Enum.map(@metrics, & &1.cpu_pct)}
            />
            <.sparkline
              id="chart-mem"
              label="Memory"
              unit="MiB"
              max={@vm.memory_mib}
              values={Enum.map(@metrics, & &1.mem_used_mib)}
            />
          </.panel>

          <.panel id="placement" title="Placement">
            <dl :if={@vm} class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-sm">
              <dt class="text-ink-3">Box</dt>
              <dd class="truncate text-ink">{@box && @box.name}</dd>
              <dt class="text-ink-3">Size</dt>
              <dd class="text-ink">
                {@size && @size.name} · {@vm.vcpus} vCPU · {gib(@vm.memory_mib)} GiB
              </dd>
              <dt class="text-ink-3">Image</dt>
              <dd class="truncate text-ink">{(@image && @image.version) || "–"}</dd>
              <dt class="text-ink-3">VM</dt>
              <dd class="truncate font-mono text-xs text-ink">{@vm.name}</dd>
            </dl>
            <p :if={@job.taken_cross_class} class="mt-2 text-xs text-ink-3">
              Taken by a runner started for [{Enum.join(@vm.class_key, ", ")}].
            </p>
            <p :if={is_nil(@vm)} class="text-sm text-ink-3">Not on a Crew VM.</p>
          </.panel>

          <.panel :if={@job.peak_mem_mib} id="summary" title="Resources used">
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-sm">
              <dt class="text-ink-3">Peak memory</dt>
              <dd class="text-ink tabular-nums">{gib(@job.peak_mem_mib)} GiB</dd>
              <dt class="text-ink-3">CPU</dt>
              <dd class="text-ink tabular-nums">
                peak {round(@job.peak_cpu_pct || 0)}%, average {round(@job.avg_cpu_pct || 0)}%
              </dd>
              <dt class="text-ink-3">Peak disk</dt>
              <dd class="text-ink tabular-nums">{gib(@job.peak_disk_mib || 0)} GiB</dd>
            </dl>
          </.panel>

          <.panel :if={@sizing || @durations != []} id="sizing" title="Right-sizing">
            <:subtitle :if={@sizing}>{SizingComponents.basis(@sizing)}</:subtitle>
            <SizingComponents.hint_details
              :if={@sizing}
              hint={@sizing}
              job={@job}
              admin={Scope.admin?(@current_scope)}
            />
            <div
              :if={@durations != []}
              id="sizing-durations"
              class={[@sizing && "mt-4 border-t border-line pt-4"]}
            >
              <p class="text-xs font-medium text-ink-2">Median time on each size</p>
              <ul class="mt-1.5 space-y-1 text-xs">
                <li :for={d <- @durations} class="flex items-baseline justify-between gap-3">
                  <span class="min-w-0 text-ink-2">{SizingComponents.shape(d.shape)}</span>
                  <span class="shrink-0 tabular-nums text-ink">
                    {JobStatus.format(d.median_s)}
                    <span class="text-ink-3">· {d.runs} {if d.runs == 1, do: "run", else: "runs"}</span>
                  </span>
                </li>
              </ul>
            </div>
          </.panel>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :step, :map, required: true

  defp step_icon(assigns) do
    ~H"""
    <span class="mt-0.5 shrink-0">
      <.icon :if={@step.conclusion == "success"} name="hero-check-circle" class="size-4 text-success" />
      <.icon :if={@step.conclusion == "failure"} name="hero-x-circle" class="size-4 text-danger" />
      <.icon
        :if={@step.conclusion in ["skipped", "cancelled"]}
        name="hero-minus-circle"
        class="size-4 text-ink-3"
      />
      <span
        :if={is_nil(@step.conclusion) and @step.status == "in_progress"}
        class="mt-1 block size-2 animate-pulse rounded-full bg-running"
      ></span>
      <.icon
        :if={is_nil(@step.conclusion) and @step.status != "in_progress"}
        name="hero-clock"
        class="size-4 text-ink-3"
      />
    </span>
    """
  end

  defp step_duration(%{started_at: %DateTime{} = from} = step, now),
    do: JobStatus.format(duration(from, step.completed_at || now))

  defp step_duration(_step, _now), do: "–"

  defp phase_title(name, {:other, _}), do: "#{name}: runner started for another job"
  defp phase_title(name, s), do: "#{name}: #{JobStatus.format(s || 0)}"

  defp phase_class(0), do: "bg-muted text-ink-2"
  defp phase_class(1), do: "bg-sky-500/15 text-ink"
  defp phase_class(2), do: "bg-amber-500/15 text-ink"
  defp phase_class(_), do: "bg-running/15 text-ink"
end
