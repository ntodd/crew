defmodule CrewWeb.RepoLive.Show do
  @moduledoc """
  A repo (§17.3): its settings (§7.4, admins), the `runs-on` snippets for
  its allowed sizes with a line on `-spare` (§7.2), its jobs' right-sizing
  hints (§7.5), its workflow schedules (§7.6, admins), its usage over 30
  days (§16.6), and the permissions its installation is missing.
  Changing settings re-parses its queued jobs.
  """
  use CrewWeb, :live_view

  alias Crew.{Jobs, Repos, Schedules, Scope, Sizes, Sizing, Usage}
  alias Crew.Schedules.Schedule
  alias CrewWeb.{SizingComponents, UsageComponents}

  @usage_days 30

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    repo = Repos.get(id)

    unless repo && Repos.can_read?(scope, repo.id),
      do: raise(Ecto.NoResultsError, queryable: Crew.Repos.Repo)

    if connected?(socket) and Scope.admin?(scope), do: Schedules.subscribe(repo.id)

    {:ok,
     socket
     |> assign(:page_title, repo.full_name)
     |> assign(:sizes, Sizes.list())
     |> assign_repo(repo)
     |> assign_schedules()
     |> assign_usage(repo)}
  end

  # Admins only (§7.6): the panel isn't rendered for members, so nothing is loaded.
  defp assign_schedules(socket) do
    %{current_scope: scope, repo: repo} = socket.assigns

    if Scope.admin?(scope) do
      socket
      |> assign(:schedules, Schedules.list(repo.id))
      |> assign(
        :schedule_form,
        schedule_form(Schedules.change(%Schedule{ref: repo.default_branch}))
      )
    else
      socket |> assign(:schedules, []) |> assign(:schedule_form, nil)
    end
  end

  defp schedule_form(changeset), do: to_form(changeset, as: :schedule)

  defp assign_usage(socket, repo) do
    scope = socket.assigns.current_scope
    today = Date.utc_today()

    socket
    |> assign(
      :usage,
      Usage.summary(scope, Date.add(today, 1 - @usage_days), today, repo_id: repo.id)
    )
    |> assign(:top_jobs, Usage.top_jobs(scope, repo, @usage_days))
  end

  defp assign_repo(socket, repo) do
    repo = Repos.with_installation(repo)

    socket
    |> assign(:repo, repo)
    |> assign(:hints, Sizing.for_repo(socket.assigns.current_scope, repo))
    |> assign(:missing, Repos.missing_permissions(repo.installation))
    |> assign(:form, to_form(Repos.change_settings(repo), as: :repo))
  end

  @impl true
  def handle_event("save", %{"repo" => params}, socket) do
    params =
      Map.update(params, "allowed_sizes", [], &Enum.reject(List.wrap(&1), fn v -> v == "" end))

    case Repos.update_settings(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, repo} ->
        Jobs.reclassify_open(repo_id: repo.id)
        {:noreply, socket |> assign_repo(repo) |> put_flash(:info, "Saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :repo, action: :update))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins change repo settings.")}
    end
  end

  # The -spare examples (§7.2) that would run here: crew-spare when the
  # default size is allowed, and the largest allowed size's. A size named
  # before the rule (`spare`, `l-spare`) keeps the label it hides.
  defp spare_examples(allowed, sizes) do
    names = MapSet.new(sizes, & &1.name)
    hidden? = &MapSet.member?(names, &1)

    default =
      if Enum.any?(allowed, & &1.is_default) and not hidden?.("spare"),
        do: ["crew-spare"],
        else: []

    sized =
      allowed
      |> Enum.map(&"#{&1.name}-spare")
      |> Enum.reject(hidden?)
      |> List.last()
      |> List.wrap()
      |> Enum.map(&("crew-" <> &1))

    default ++ sized
  end

  def handle_event("create_schedule", %{"schedule" => params}, socket) do
    case Schedules.create(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, _schedule} ->
        {:noreply, socket |> assign_schedules() |> put_flash(:info, "Schedule added.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :schedule_form, schedule_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins change schedules.")}
    end
  end

  def handle_event("run_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      case Schedules.run_now(socket.assigns.current_scope, schedule) do
        {:ok, s} ->
          put_flash(socket, :info, "Started #{s.workflow} on #{s.ref}.")

        {:error, %Schedule{last_error: error}} ->
          put_flash(socket, :error, "GitHub refused: #{error}")

        {:error, :unauthorized} ->
          put_flash(socket, :error, "Only admins run schedules.")
      end
    end)
  end

  def handle_event("toggle_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      scope = socket.assigns.current_scope

      case Schedules.update(scope, schedule, %{"enabled" => !schedule.enabled}) do
        {:ok, _} -> socket
        {:error, _} -> put_flash(socket, :error, "Only admins change schedules.")
      end
    end)
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      case Schedules.delete(socket.assigns.current_scope, schedule) do
        {:ok, _} -> put_flash(socket, :info, "Schedule removed.")
        {:error, _} -> put_flash(socket, :error, "Only admins change schedules.")
      end
    end)
  end

  # Acts on one of this repo's schedules, as listed: an id from elsewhere does nothing.
  defp with_schedule(socket, id, fun) do
    case Enum.find(socket.assigns.schedules, &(&1.id == id)) do
      %Schedule{} = schedule -> {:noreply, schedule |> fun.() |> assign_schedules()}
      nil -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:schedules_changed, _repo_id}, socket),
    do: {:noreply, assign_schedules(socket)}

  defp allowed(repo, sizes) do
    sizes
    |> Enum.reject(&(&1.retired_at != nil))
    |> Enum.filter(&(repo.allowed_sizes == nil or &1.name in repo.allowed_sizes))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb navigate={~p"/repos"}>Repos</:breadcrumb>
      <:breadcrumb>{@repo.full_name}</:breadcrumb>

      <.header>
        {@repo.full_name}
        <:subtitle>
          {if @repo.private, do: "Private", else: "Public"} · default branch {@repo.default_branch}
        </:subtitle>
      </.header>

      <.callout
        :if={@missing != []}
        id="missing-permissions"
        kind="warning"
        icon="hero-exclamation-triangle"
      >
        The installation is missing permissions Crew needs, so its jobs can't run: {Enum.map_join(
          @missing,
          ", ",
          fn {p, l} -> "#{p} (#{l})" end
        )}. Accept the new permissions on GitHub.
      </.callout>

      <div class="grid gap-4 lg:grid-cols-2">
        <.panel id="snippets" title="runs-on">
          <:subtitle>
            Copy one into a job. Only runners with exactly that label take its jobs.
          </:subtitle>
          <ul class="space-y-2">
            <li :for={size <- allowed(@repo, @sizes)} class="flex items-center justify-between gap-3">
              <code class="rounded-md border border-line bg-subtle px-2 py-1 font-mono text-xs text-ink">runs-on: crew-{size.name}</code>
              <span class="text-xs text-ink-3">
                {size.vcpus} vCPU · {div(size.memory_mib, 1024)} GiB · {size.disk_gib} GiB disk
              </span>
            </li>
          </ul>
          <p
            :if={(examples = spare_examples(allowed(@repo, @sizes), @sizes)) != []}
            id="spare-hint"
            class="mt-3 text-xs text-ink-3"
          >
            Add <code class="font-mono text-ink-2">-spare</code>
            for background work that only gets room regular jobs aren't using:
            <%= for {label, i} <- Enum.with_index(examples) do %>
              <span :if={i > 0}>or</span>
              <code class="font-mono text-ink-2">runs-on: {label}</code>
            <% end %>.
          </p>
        </.panel>

        <.panel :if={Scope.admin?(@current_scope)} id="settings" title="Settings">
          <.form for={@form} id="repo-settings" phx-submit="save" class="space-y-1">
            <.input field={@form[:enabled]} type="checkbox" label="Run this repo's Crew jobs" />
            <fieldset class="mb-3">
              <legend class="label">Allowed sizes</legend>
              <p class="mb-2 text-xs text-ink-3">None ticked: every size.</p>
              <input type="hidden" name="repo[allowed_sizes][]" value="" />
              <div class="flex flex-wrap gap-x-4 gap-y-2">
                <label :for={size <- @sizes} class="flex items-center gap-2 text-sm text-ink">
                  <input
                    type="checkbox"
                    class="checkbox"
                    name="repo[allowed_sizes][]"
                    value={size.name}
                    checked={size.name in (@form[:allowed_sizes].value || [])}
                  />
                  {size.name}
                </label>
              </div>
            </fieldset>
            <.input
              field={@form[:max_concurrent]}
              type="number"
              label="Most VMs at once (blank: no cap)"
            />
            <.input
              field={@form[:fork_prs]}
              type="select"
              label="Fork PRs"
              options={[{"Refuse", "refuse"}, {"Allow", "allow"}]}
            />
            <.input field={@form[:priority]} type="number" label="Priority (higher is placed first)" />
            <div class="pt-2">
              <.button type="submit" variant="primary" size="sm">Save</.button>
            </div>
          </.form>
        </.panel>
      </div>

      <.panel :if={Scope.admin?(@current_scope)} id="schedules" title="Schedules" class="mt-4">
        <:subtitle>
          Crew starts these workflows on time, with <code>workflow_dispatch</code>, where GitHub's own
          <code>schedule:</code>
          trigger can run hours late. Each workflow needs a <code>workflow_dispatch</code>
          trigger; drop its <code>schedule:</code>
          so GitHub doesn't start it again later. Times are UTC.
        </:subtitle>
        <p :if={@schedules == []} id="schedules-empty" class="text-sm text-ink-3">
          No schedules yet.
        </p>
        <ul :if={@schedules != []} id="schedules-list" class="-my-3 divide-y divide-line">
          <li
            :for={s <- @schedules}
            id={"schedule-#{s.id}"}
            class="grid gap-x-6 gap-y-1.5 py-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start"
          >
            <div class="min-w-0">
              <p class="text-sm text-ink">
                <span class="font-mono">{s.workflow}</span>
                <span class="text-ink-3">on</span>
                <span class="font-mono">{s.ref}</span>
                <.badge :if={!s.enabled} size="sm" class="ml-1">Off</.badge>
              </p>
              <p class="mt-0.5 text-xs text-ink-3">
                <code class="rounded-md border border-line bg-subtle px-1.5 py-0.5 font-mono text-ink-2">{s.cron}</code>
                <span :if={s.enabled}>
                  · next <.local_time id={"schedule-#{s.id}-next"} at={Schedules.next_at(s)} />
                </span>
                <span :if={s.last_dispatched_at}>
                  · last started
                  <.local_time
                    id={"schedule-#{s.id}-last"}
                    at={s.last_dispatched_at}
                    format="relative"
                  />
                </span>
              </p>
              <p :if={s.last_error} class="mt-0.5 text-xs text-danger">
                Last dispatch failed: {s.last_error}
              </p>
            </div>
            <div class="space-x-3 whitespace-nowrap text-xs">
              <button
                type="button"
                phx-click="run_schedule"
                phx-value-id={s.id}
                class="underline-offset-2 hover:underline"
              >Run now</button>
              <button
                type="button"
                phx-click="toggle_schedule"
                phx-value-id={s.id}
                class="underline-offset-2 hover:underline"
              >{if s.enabled, do: "Disable", else: "Enable"}</button>
              <button
                type="button"
                phx-click="delete_schedule"
                phx-value-id={s.id}
                data-confirm={"Remove the schedule for #{s.workflow}?"}
                class="text-danger underline-offset-2 hover:underline"
              >Remove</button>
            </div>
          </li>
        </ul>
        <.form
          for={@schedule_form}
          id="schedule-form"
          phx-submit="create_schedule"
          class="mt-4 grid gap-x-3 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-start"
        >
          <.input
            field={@schedule_form[:workflow]}
            label="Workflow file"
            placeholder="flake-hunt.yml"
          />
          <.input field={@schedule_form[:ref]} label="Branch or tag" />
          <.input field={@schedule_form[:cron]} label="Cron (UTC)" placeholder="17 7 * * *" />
          <div class="pt-6">
            <.button type="submit" size="sm">Add schedule</.button>
          </div>
        </.form>
      </.panel>

      <.panel id="sizing" title="Right-sizing" class="mt-4">
        <:subtitle>
          From each job's last runs over 30 days. Memory is what limits how many jobs a box takes at once.
        </:subtitle>
        <p :if={@hints == []} id="sizing-empty" class="text-sm text-ink-3">
          Nothing to change. A job needs 5 complete runs on its size before Crew suggests a smaller one.
        </p>
        <ul :if={@hints != []} id="sizing-hints" class="-my-3 divide-y divide-line">
          <li
            :for={h <- @hints}
            id={"sizing-#{h.job.id}"}
            class="grid gap-x-6 gap-y-1.5 py-3 sm:grid-cols-[minmax(0,13rem)_minmax(0,1fr)_auto] sm:items-start"
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
              <p class="mt-0.5 text-xs text-ink-3">{SizingComponents.shape(h.hint.from)}</p>
            </div>
            <div class="min-w-0">
              <.badge color={SizingComponents.color(h.hint)}>{SizingComponents.title(h.hint)}</.badge>
              <p class="mt-1 text-xs text-ink-2">{List.first(h.hint.reasons)}</p>
            </div>
            <p class="whitespace-nowrap text-xs text-ink-2 sm:text-right">
              {SizingComponents.saving(h.hint)}
            </p>
          </li>
        </ul>
      </.panel>

      <UsageComponents.repo_panel summary={@usage} top_jobs={@top_jobs} />
    </Layouts.app>
    """
  end
end
