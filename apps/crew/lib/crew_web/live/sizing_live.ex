defmodule CrewWeb.SizingLive do
  @moduledoc """
  Right-sizing across the fleet (§7.5): the memory the last week's runs
  reserved against the most they used, what the hints would free, each
  repo's share, and every hint, the most to free first. Only the repos
  the viewer can read count.
  """
  use CrewWeb, :live_view

  alias Crew.Sizing
  alias CrewWeb.{SizingActions, SizingComponents, SizingIssue}

  @sizing_events SizingActions.events()

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Right-sizing")
     |> assign(:admin, Crew.Scope.admin?(socket.assigns.current_scope))
     |> assign(:fleet, fleet(socket.assigns.current_scope))
     |> SizingActions.mount()}
  end

  @impl true
  def handle_event(event, params, socket) when event in @sizing_events,
    do:
      SizingActions.handle(event, params, socket, fn socket ->
        assign(socket, :fleet, fleet(socket.assigns.current_scope))
      end)

  # The fleet, each hint with its issue (`CrewWeb.SizingIssue`), and each
  # repo with one for its hints.
  defp fleet(scope) do
    crew = Crew.Config.base_url()
    fleet = Sizing.fleet(scope)
    by_repo = Enum.group_by(fleet.hints, & &1.repo.id)

    %{
      fleet
      | hints: SizingIssue.put_issues(fleet.hints, crew),
        repos:
          Enum.map(fleet.repos, fn r ->
            Map.put(
              r,
              :issue,
              SizingIssue.for_repo(r.repo, Map.get(by_repo, r.repo.id, []), crew)
            )
          end)
    }
  end

  defdelegate gib_h(x), to: SizingComponents

  # A net change in words: what applying the hints frees or takes.
  defp net(x) when x < 0, do: "takes #{gib_h(-x)}"
  defp net(x), do: "frees #{gib_h(x)}"

  defp change(%{freed_gib_h: f, taken_gib_h: t}) when t > 0,
    do: "frees #{gib_h(f)}, takes #{gib_h(t)} GiB-hours"

  defp change(%{freed_gib_h: f, reserved_gib_h: r}),
    do: share(f, r) || "GiB-hours"

  defp share(_part, total) when total <= 0, do: nil
  defp share(part, total), do: "#{round(part / total * 100)}% of reserved"

  defp week(%{freed_gib_h: f}) when f > 0, do: "frees #{gib_h(f)} GiB-hours a week"
  defp week(%{freed_gib_h: f}) when f < 0, do: "takes #{gib_h(-f)} GiB-hours a week"
  defp week(%{hint: hint}), do: SizingComponents.saving(hint)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Right-sizing</:breadcrumb>

      <.header>
        Right-sizing
        <:subtitle>
          The memory Crew's jobs reserved over the last {@fleet.days} days, the most they used, and the sizes that would fit them better.
        </:subtitle>
      </.header>

      <section id="sizing-totals" class="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
          <p class="text-xs text-ink-3">Reserved</p>
          <p id="sizing-reserved" class="text-2xl font-semibold tabular-nums text-ink">
            {gib_h(@fleet.reserved_gib_h)}
          </p>
          <p class="text-xs text-ink-3">GiB-hours</p>
        </div>
        <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
          <p class="text-xs text-ink-3">Peak used</p>
          <p id="sizing-used" class="text-2xl font-semibold tabular-nums text-ink">
            {gib_h(@fleet.used_gib_h)}
          </p>
          <p class="text-xs text-ink-3">
            {share(@fleet.used_gib_h, @fleet.reserved_gib_h) || "GiB-hours"}
          </p>
        </div>
        <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
          <p class="text-xs text-ink-3">
            Applying the hints would {if @fleet.net_gib_h < 0, do: "take", else: "free"}
          </p>
          <p id="sizing-net" class="text-2xl font-semibold tabular-nums text-ink">
            {gib_h(abs(@fleet.net_gib_h))}
          </p>
          <p class="text-xs text-ink-3">{change(@fleet)}</p>
        </div>
        <div class="rounded-xl border border-line bg-raised p-4 shadow-xs">
          <p class="text-xs text-ink-3">Need more memory</p>
          <p id="sizing-needs-more" class="text-2xl font-semibold tabular-nums text-ink">
            {@fleet.needs_more}
          </p>
          <p class="text-xs text-ink-3">{if @fleet.needs_more == 1, do: "job", else: "jobs"}</p>
        </div>
      </section>

      <.panel id="sizing-hints-panel" title="Hints" class="mb-4">
        <:subtitle>
          Each job's suggestion from its last runs, the most memory it would free in a week first.
        </:subtitle>
        <p :if={@fleet.hints == []} id="sizing-hints-empty" class="text-sm text-ink-3">
          <%= if @fleet.dismissed == [] do %>
            Nothing to change. A job needs 5 complete runs on its size before Crew suggests a smaller one.
          <% else %>
            Nothing left to change: every hint is dismissed.
          <% end %>
        </p>
        <ul :if={@fleet.hints != []} id="sizing-hints" class="-my-3 divide-y divide-line">
          <li
            :for={h <- @fleet.hints}
            id={"sizing-#{h.job.id}"}
            class="grid gap-x-6 gap-y-1.5 py-3 sm:grid-cols-[minmax(0,15rem)_minmax(0,1fr)_auto] sm:items-start"
          >
            <div class="min-w-0">
              <.link
                navigate={
                  ~p"/runs/#{h.job.github_run_id}/attempts/#{h.job.run_attempt}/jobs/#{h.job.github_id}"
                }
                class="text-sm font-medium text-ink underline-offset-2 hover:underline"
              >
                {h.workflow_name} · {h.name}
              </.link>
              <p class="mt-0.5 truncate text-xs text-ink-3">{h.repo.full_name}</p>
              <p class="text-xs text-ink-3">{SizingComponents.shape(h.hint.from)}</p>
            </div>
            <div class="min-w-0">
              <.badge color={SizingComponents.color(h.hint)}>{SizingComponents.title(h.hint)}</.badge>
              <p class="mt-1 text-xs text-ink-2">{List.first(h.hint.reasons)}</p>
            </div>
            <div class="space-y-1 sm:text-right">
              <p class="whitespace-nowrap text-xs text-ink-2">{week(h)}</p>
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 sm:justify-end">
                <SizingComponents.issue_actions
                  :if={h.issue}
                  id={"sizing-#{h.job.id}-issue"}
                  issue={h.issue}
                  compact
                />
                <.link
                  :if={@admin and h.hint.kind == :custom}
                  href={SizingComponents.add_size_path(h.hint.to, [h.repo.id])}
                  class="whitespace-nowrap text-xs text-ink-2 underline-offset-2 hover:text-ink hover:underline"
                >
                  Add this size
                </.link>
                <SizingComponents.dismiss_button
                  :if={@admin and @dismissing != h.job.id}
                  job_id={h.job.id}
                />
              </div>
            </div>
            <SizingComponents.dismiss_form
              :if={@admin and @dismissing == h.job.id}
              id={"sizing-#{h.job.id}-dismiss"}
              job_id={h.job.id}
              hint={h.hint}
              class="sm:col-span-3 sm:justify-end"
            />
          </li>
        </ul>
        <SizingComponents.dismissed_list
          hints={@fleet.dismissed}
          open={@show_dismissed}
          admin={@admin}
          repo
        />
      </.panel>

      <.panel
        :if={@fleet.custom != []}
        id="sizing-custom"
        title="Sizes that would fit"
        class="mb-4"
      >
        <:subtitle>
          The custom hints by the shape they'd fit: one size an admin adds can serve all of a shape's jobs.
        </:subtitle>
        <ul class="-my-3 divide-y divide-line">
          <li
            :for={c <- @fleet.custom}
            id={"sizing-custom-#{c.shape.vcpus}-#{c.shape.memory_mib}-#{c.shape.disk_gib}"}
            class="grid gap-x-6 gap-y-1.5 py-3 sm:grid-cols-[minmax(0,15rem)_minmax(0,1fr)_auto] sm:items-start"
          >
            <div class="min-w-0">
              <p class="text-sm font-medium text-ink">{SizingComponents.shape(c.shape)}</p>
              <p class="mt-0.5 text-xs text-ink-3">
                {length(c.hints)} {if length(c.hints) == 1, do: "job", else: "jobs"}
              </p>
            </div>
            <ul class="min-w-0 space-y-0.5 text-xs">
              <li :for={h <- c.hints} class="truncate">
                <.link
                  navigate={
                    ~p"/runs/#{h.job.github_run_id}/attempts/#{h.job.run_attempt}/jobs/#{h.job.github_id}"
                  }
                  class="text-ink-2 underline-offset-2 hover:text-ink hover:underline"
                >
                  {h.workflow_name} · {h.name}
                </.link>
                <span class="text-ink-3">{h.repo.full_name}</span>
              </li>
            </ul>
            <div class="space-y-1 sm:text-right">
              <p :if={c.freed_gib_h > 0} class="whitespace-nowrap text-xs text-ink-2">
                frees {gib_h(c.freed_gib_h)} GiB-hours a week
              </p>
              <.link
                :if={@admin}
                href={SizingComponents.add_size_path(c.shape, Enum.map(c.hints, & &1.repo.id))}
                class="whitespace-nowrap text-xs text-ink-2 underline-offset-2 hover:text-ink hover:underline"
              >
                Add this size
              </.link>
              <p :if={!@admin} class="text-xs text-ink-3">An admin can add it on Sizes & labels.</p>
            </div>
          </li>
        </ul>
      </.panel>

      <.panel id="sizing-repos" title="By repo">
        <:subtitle>Over the last {@fleet.days} days, in GiB-hours.</:subtitle>
        <p :if={@fleet.repos == []} id="sizing-repos-empty" class="text-sm text-ink-3">
          No runs with resource summaries yet.
        </p>
        <.table :if={@fleet.repos != []} id="sizing-repo-rows" rows={@fleet.repos}>
          <:col :let={r} label="Repo">
            <.link
              navigate={~p"/repos/#{r.repo.id}"}
              class="font-medium text-ink underline-offset-2 hover:underline"
            >
              {r.repo.full_name}
            </.link>
            <SizingComponents.issue_actions
              :if={r.issue}
              id={"sizing-repo-#{r.repo.id}-issue"}
              issue={r.issue}
              compact
              align="start"
              class="mt-1 flex-col items-start sm:flex-row sm:items-center"
            />
          </:col>
          <:col :let={r} label="Runs" align="right" class="hidden tabular-nums sm:table-cell">
            {r.runs}
          </:col>
          <:col :let={r} label="Reserved" align="right" class="hidden tabular-nums sm:table-cell">
            {gib_h(r.reserved_gib_h)}
          </:col>
          <:col :let={r} label="Peak used" align="right" class="whitespace-nowrap tabular-nums">
            {gib_h(r.used_gib_h)}
            <span :if={r.reserved_gib_h > 0} class="text-ink-3">
              ({round(r.used_gib_h / r.reserved_gib_h * 100)}%)
            </span>
          </:col>
          <:col :let={r} label="Hints, net" align="right" class="whitespace-nowrap tabular-nums">
            {net(r.net_gib_h)}
          </:col>
        </.table>
      </.panel>
    </Layouts.app>
    """
  end
end
