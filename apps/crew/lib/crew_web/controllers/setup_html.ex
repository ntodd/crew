defmodule CrewWeb.SetupHTML do
  use CrewWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="narrow">
      <div class="rounded-2xl border border-line bg-raised p-8 shadow-raised">
        <div class="mb-6">
          <p class="text-xs font-medium uppercase tracking-wide text-accent-ink">First run</p>
          <h1 class="mt-1 text-xl font-semibold tracking-tight text-ink">
            Connect Crew to GitHub
          </h1>
          <p class="mt-1.5 text-sm text-ink-2">
            Crew takes GitHub's workflow_job webhooks, registers a single-use runner for each job and signs people in, all through one GitHub App. Creating it takes one click.
          </p>
        </div>

        <%= if @verified do %>
          <.form for={%{}} id="setup-host" action={~p"/setup/github"} method="post" class="space-y-4">
            <.input
              name="host"
              value={@host}
              label="Tailnet host"
              placeholder="crew.tail1234.ts.net"
              required
            />
            <p class="text-xs text-ink-3">
              The name this control plane has on your tailnet. People reach it there through tailscale serve on 443, and GitHub sends webhooks to it through Tailscale Funnel on 8443. Every URL in the App is built from it.
            </p>
            <.input
              name="org"
              value=""
              label="Organization (optional)"
              placeholder="Leave empty to create it on your own account"
            />
            <.button type="submit" variant="primary" class="w-full justify-center">Continue</.button>
          </.form>
        <% else %>
          <.form for={%{}} id="setup-token" action={~p"/setup"} class="space-y-4">
            <.input name="token" value="" label="Setup token" autocomplete="off" required />
            <p class="text-xs text-ink-3">
              It's printed in the control plane's log when it starts without a GitHub App.
            </p>
            <.button type="submit" variant="primary" class="w-full justify-center">Verify</.button>
          </.form>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  def github(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="narrow">
      <div class="rounded-2xl border border-line bg-raised p-8 shadow-raised">
        <h1 class="text-xl font-semibold tracking-tight text-ink">Create the GitHub App</h1>
        <p class="mt-1.5 text-sm text-ink-2">
          GitHub will show you the App's settings. It asks for Administration (write) to register single-use runners, Actions (write) to read jobs and logs and to cancel runs, and Pull requests and Members (read). Click "Create GitHub App" there, and you'll come back here.
        </p>
        <form id="setup-manifest" action={@action} method="post" class="mt-6">
          <input type="hidden" name="manifest" value={@manifest} />
          <.button
            type="submit"
            variant="primary"
            class="w-full justify-center"
            icon="hero-arrow-top-right-on-square"
          >
            Continue on GitHub
          </.button>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
