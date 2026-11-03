defmodule CrewWeb.AdminLive.Deployment do
  @moduledoc """
  The deployment at a glance (§17.3): Crew's version, the GitHub App,
  the deployment id and public host, the webhook Funnel URL, the
  database, and the release key's fingerprint.
  """
  use CrewWeb, :live_view

  alias Crew.{GitHub, Settings}

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
     |> load_github()}
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
              <dd class="mt-0.5 font-mono text-ink">
                {if @public_host, do: "https://#{@public_host}", else: "not set"}
              </dd>
            </div>
            <div>
              <dt class="text-ink-2">Webhooks (Tailscale Funnel on 8443)</dt>
              <dd id="funnel-url" class="mt-0.5 font-mono text-ink">
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
