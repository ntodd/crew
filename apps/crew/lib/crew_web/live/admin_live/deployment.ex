defmodule CrewWeb.AdminLive.Deployment do
  @moduledoc """
  The deployment at a glance (§17.3): Crew's version and updates
  (§20.3), the GitHub App, the deployment id and public host, the
  webhook Funnel URL, the database, and the release key's fingerprint.
  """
  use CrewWeb, :live_view

  alias Crew.{GitHub, Settings, Updates}

  # How often the page rereads the host's updater while it works.
  @update_poll 2_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Deployment")
     |> assign(:github_app, GitHub.app())
     |> assign(:deployment_id, Settings.deployment_id())
     |> assign(:public_host, Settings.public_host())
     |> assign(:release_fingerprint, Crew.Config.release_key_fingerprint())
     |> assign(:pinging, false)
     |> assign(:checking_updates, false)
     |> load_github()
     |> load_update()}
  end

  defp load_update(socket) do
    updater = Updates.updater()

    if connected?(socket) and updater.state in ["pending", "running"],
      do: Process.send_after(self(), :refresh_update, @update_poll)

    assign(socket,
      check_enabled: Updates.enabled?(),
      update_repo: Updates.repo(),
      latest: Updates.latest(),
      available: Updates.available(),
      updater: updater
    )
  end

  defp load_github(socket) do
    socket
    |> assign(:webhooks_on, Application.get_env(:crew, :webhooks, true))
    |> assign(:hooks, Crew.GitHub.HookHealth.summary())
    |> assign(
      :budgets,
      for(i <- Crew.Repos.list_installations(), do: {i, Crew.GitHub.Budget.info(i.github_id)})
    )
  end

  @impl true
  def handle_event("ping", _params, socket) do
    socket = assign(socket, :pinging, true)

    case Crew.GitHub.HookHealth.send_ping() do
      :ok ->
        {:noreply,
         socket
         |> assign(:pinging, false)
         |> put_flash(:info, "Asked GitHub to send the ping again.")}

      {:error, message} ->
        {:noreply, socket |> assign(:pinging, false) |> put_flash(:error, message)}
    end
  end

  def handle_event("update_crew", _params, socket) do
    result =
      case socket.assigns.available do
        %{version: version} -> Updates.request(socket.assigns.current_scope, version)
        nil -> {:error, :not_available}
      end

    case result do
      :ok ->
        {:noreply, load_update(socket)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, update_error(reason)) |> load_update()}
    end
  end

  def handle_event("check_for_updates", _params, socket) do
    {:noreply,
     socket
     |> assign(:checking_updates, true)
     |> start_async(:check_updates, fn -> Updates.check() end)}
  end

  defp update_error(:in_progress), do: "An update is already under way."
  defp update_error(:no_updater), do: "The host's updater isn't installed."
  defp update_error(:not_available), do: "That release is no longer the newest; check again."
  defp update_error(:forbidden), do: "Only admins can update Crew."
  defp update_error(reason), do: "Couldn't ask the host to update: #{inspect(reason)}"

  @impl true
  def handle_async(:check_updates, result, socket) do
    socket = socket |> assign(:checking_updates, false) |> load_update()

    case result do
      {:ok, {:ok, _}} -> {:noreply, socket}
      _ -> {:noreply, put_flash(socket, :error, "Couldn't check GitHub for releases.")}
    end
  end

  @impl true
  def handle_info(:refresh_update, socket), do: {:noreply, load_update(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  # From the image the control plane runs: the updater installs the copy
  # it carries.
  defp install_command do
    ~s|img=$(sudo docker inspect -f '{{.Config.Image}}' crew) && | <>
      ~s|sudo docker run --rm --entrypoint cat "$img" /app/updater/crew-update | <>
      ~s|\| sudo sh -s -- install /path/to/compose.yml|
  end

  defp last_update(%{state: "stale", to: to}),
    do: "The update to #{to} stopped reporting. journalctl -u crew-update on the host says why."

  defp last_update(%{message: message, at: %DateTime{} = at}),
    do: "#{message} (#{Calendar.strftime(at, "%b %-d, %H:%M UTC")})"

  defp last_update(%{message: message}), do: message

  defp format_at(nil), do: "never"
  defp format_at(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %H:%M:%S UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Deployment</:breadcrumb>

      <.header>
        Deployment
        <:subtitle>How this Crew is wired up.</:subtitle>
      </.header>

      <.panel id="crew-update" title="Updates" class="mb-4">
        <:subtitle>
          Running Crew {Crew.Config.version()}. Releases come from {@update_repo}{if @check_enabled,
            do: ", checked daily"}.
          <span :if={@latest && @latest.checked_at}>
            Last checked
            <.local_time id="update-checked-at" at={@latest.checked_at} format="relative" />
          </span>
        </:subtitle>
        <:actions :if={@check_enabled}>
          <.button
            id="check-for-updates"
            size="sm"
            variant="ghost"
            phx-click="check_for_updates"
            disabled={@checking_updates}
          >{if @checking_updates, do: "Checking…", else: "Check now"}</.button>
        </:actions>
        <div class="space-y-3 text-sm">
          <%= cond do %>
            <% @updater.state == "pending" -> %>
              <p class="text-ink">
                <.badge color="amber" dot pulse>Updating</.badge>
                <span class="ml-1">Waiting for the host's updater to pick up {@updater.to}.</span>
              </p>
            <% @updater.state == "running" -> %>
              <p class="text-ink">
                <.badge color="amber" dot pulse>Updating</.badge>
                <span class="ml-1">{@updater.message}</span>
              </p>
              <p class="text-ink-2">
                The page reconnects once {@updater.to} is up. Jobs keep running, and boxes reconnect when it's back.
              </p>
            <% not @check_enabled -> %>
              <p id="update-check-off" class="text-ink-2">
                Update checks are off (CREW_UPDATE_CHECK=false).
              </p>
            <% @available -> %>
              <div id="crew-update-available" class="space-y-3">
                <p class="text-ink">
                  Crew {@available.version} is available.
                  <a
                    :if={@available.url}
                    href={@available.url}
                    class="font-medium text-accent-ink underline"
                    target="_blank"
                    rel="noopener"
                  >Release notes</a>
                </p>
                <%= if @updater.installed do %>
                  <.button
                    id="update-crew"
                    variant="primary"
                    size="sm"
                    phx-click="update_crew"
                    data-confirm={"Update Crew to #{@available.version} and restart it? The host backs up the data first, and goes back if #{@available.version} doesn't come up. Jobs keep running; boxes reconnect, then update their agents."}
                  >Update to {@available.version}</.button>
                <% else %>
                  <div id="install-updater" class="space-y-2">
                    <p class="text-ink-2">
                      To update from here, install the updater on this host once, with the path to the control plane's compose.yml (crew-update; see docs/setup/upgrading.md):
                    </p>
                    <.command id="install-updater-command" command={install_command()} />
                  </div>
                <% end %>
              </div>
            <% @latest && @latest.version -> %>
              <p class="text-ink">
                <.badge color="emerald" dot>Up to date</.badge>
                <span class="ml-1 text-ink-2">The newest release is {@latest.version}.</span>
              </p>
            <% @latest && is_nil(@latest.error) -> %>
              <p class="text-ink-3">{@update_repo} has no releases yet.</p>
            <% is_nil(@latest) -> %>
              <p class="text-ink-3">Not checked for releases yet.</p>
            <% true -> %>
          <% end %>

          <p :if={@check_enabled && @latest && @latest.error} class="text-ink-3">
            The last check failed: {@latest.error}
          </p>

          <p
            :if={@updater.state in ["succeeded", "failed", "rolled_back", "stale"]}
            id="last-update"
            class={[
              @updater.state == "succeeded" && "text-ink-2",
              @updater.state != "succeeded" && "text-danger"
            ]}
          >
            {last_update(@updater)}
          </p>
        </div>
      </.panel>

      <div class="grid gap-4 md:grid-cols-2">
        <.panel id="deployment-crew" title="Crew">
          <dl class="space-y-2 text-sm">
            <div class="flex justify-between gap-4">
              <dt class="text-ink-2">Version</dt>
              <dd class="font-mono text-ink">{Crew.Config.version()}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-ink-2">Deployment id</dt>
              <dd id="deployment-id" class="font-mono text-ink">{@deployment_id || "not set"}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-ink-2">Database</dt>
              <dd class="text-ink">{if Crew.Repo.sqlite?(), do: "SQLite", else: "Postgres"}</dd>
            </div>
          </dl>
        </.panel>

        <.panel id="deployment-github" title="GitHub App">
          <%= if @github_app do %>
            <.badge color="emerald" dot>Connected</.badge>
            <p :if={@github_app[:slug]} class="mt-2 text-sm text-ink-2">
              <a
                href={"https://github.com/apps/#{@github_app.slug}"}
                class="font-medium text-accent-ink underline"
                target="_blank"
                rel="noopener"
              >{@github_app.slug}</a>
            </p>
          <% else %>
            <.badge color="amber" dot>Not set up</.badge>
            <p class="mt-2 text-sm text-ink-2">
              Run setup, or set CREW_GITHUB_* in the environment.
            </p>
          <% end %>
        </.panel>

        <.panel id="deployment-hosts" title="Addresses">
          <dl class="space-y-2 text-sm">
            <div>
              <dt class="text-ink-2">The UI (tailnet only, through tailscale serve)</dt>
              <dd class="mt-0.5 break-all font-mono text-ink">
                {if @public_host, do: "https://#{@public_host}", else: "not set"}
              </dd>
            </div>
            <div>
              <dt class="text-ink-2">Webhooks (Tailscale Funnel on 8443)</dt>
              <dd id="funnel-url" class="mt-0.5 break-all font-mono text-ink">
                {if @public_host, do: "https://#{@public_host}:8443/hooks/github", else: "not set"}
              </dd>
            </div>
          </dl>
        </.panel>

        <.panel id="deployment-webhooks" title="Webhooks">
          <:actions>
            <.button id="send-ping" size="sm" variant="ghost" phx-click="ping" disabled={@pinging}>
              Send ping
            </.button>
          </:actions>
          <p :if={not @webhooks_on} class="mb-3 text-sm text-warning">
            Poll-only mode (CREW_WEBHOOKS=off): jobs may wait up to the poll interval before Crew sees them.
          </p>
          <dl class="space-y-2 text-sm">
            <div class="flex justify-between gap-4">
              <dt class="text-ink-2">Last delivery</dt>
              <dd id="last-delivery" class="text-ink">{format_at(@hooks.last_received_at)}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-ink-2">Failed (24 h)</dt>
              <dd id="failed-deliveries" class="text-ink">{@hooks.failed_24h}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-ink-2">Last ping</dt>
              <dd id="last-ping" class="text-ink">{format_at(@hooks.last_ping_at)}</dd>
            </div>
          </dl>
        </.panel>

        <.panel id="deployment-budget" title="GitHub budget">
          <:subtitle>Per installation, from the rate-limit headers on Crew's own calls.</:subtitle>
          <ul class="space-y-2 text-sm">
            <li :for={{i, b} <- @budgets} class="flex justify-between gap-4">
              <span class="text-ink">{i.account_login}</span>
              <span class="tabular-nums text-ink-2">
                {if b.limit, do: "#{b.remaining} of #{b.limit} left", else: "no calls yet"}
              </span>
            </li>
            <li :if={@budgets == []} class="text-ink-3">No installations yet.</li>
          </ul>
        </.panel>

        <.panel id="deployment-release-key" title="Release key">
          <:subtitle>
            Agents, caches and guest images are signed with it. Compare it with the fingerprint in Crew's README and release notes before adding a box.
          </:subtitle>
          <p id="release-fingerprint" class="break-all font-mono text-xs text-ink">
            {@release_fingerprint || "No release key configured (CREW_RELEASE_PUBLIC_KEY)."}
          </p>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
