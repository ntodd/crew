defmodule CrewWeb.RepoLive.Show do
  @moduledoc """
  A repo (§17.3): its settings (§7.4, admins), the `runs-on` snippets for
  its allowed sizes and its jobs' right-sizing hints (§7.5), and the
  permissions its installation is missing. Changing settings re-parses
  its queued jobs.
  """
  use CrewWeb, :live_view

  alias Crew.{Jobs, Repos, Scope, Sizes, Sizing}
  alias CrewWeb.SizingComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    repo = Repos.get(id)

    unless repo && Repos.can_read?(scope, repo.id),
      do: raise(Ecto.NoResultsError, queryable: Crew.Repos.Repo)

    {:ok,
     socket
     |> assign(:page_title, repo.full_name)
     |> assign(:sizes, Sizes.list())
     |> assign_repo(repo)}
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
    </Layouts.app>
    """
  end
end
