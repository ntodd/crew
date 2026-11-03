defmodule CrewWeb.DashboardLive do
  @moduledoc """
  The dashboard (§17.3). This first version has the empty states and
  the activity feed; the fleet strip, counters and charts come with the
  scheduler and boxes.
  """
  use CrewWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:activity, Crew.Activity.recent(socket.assigns.current_scope, 20))}
  end

  # The feed updates live (UserAuth shows the notice and passes it on).
  @impl true
  def handle_info({:activity, event}, socket) do
    event = Crew.Activity.for_scope(event, socket.assigns.current_scope)
    {:noreply, update(socket, :activity, &Enum.take([event | &1], 20))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Dashboard</:breadcrumb>

      <.header>
        Dashboard
        <:subtitle>Jobs, boxes and what's waiting.</:subtitle>
      </.header>

      <.panel id="dashboard-empty" title="Get started">
        <div class="space-y-3 text-sm text-ink-2">
          <p id="empty-boxes">
            <span class="font-medium text-ink">Add your first box.</span>
            Boxes are the machines that run job VMs.
          </p>
          <p id="empty-repos">
            <span class="font-medium text-ink">Install the App on a repo.</span>
            Crew only sees jobs from repos the GitHub App is installed on.
          </p>
          <div id="empty-jobs">
            <p>Then ask for a Crew runner in a workflow:</p>
            <pre class="mt-2 rounded-lg border border-line bg-subtle px-3 py-2 font-mono text-xs text-ink">runs-on: crew-m</pre>
          </div>
        </div>
      </.panel>

      <.panel id="activity" title="Activity" padded={false}>
        <ul :if={@activity != []} class="divide-y divide-line">
          <li :for={event <- @activity} id={"activity-#{event.id}"} class="px-5 py-2.5 text-sm">
            <span class="text-ink">{event.message}</span>
            <span class="ml-2 text-xs text-ink-3">
              {Calendar.strftime(event.inserted_at, "%b %-d, %H:%M UTC")}
            </span>
          </li>
        </ul>
        <p :if={@activity == []} class="px-5 py-4 text-sm text-ink-3">Nothing yet.</p>
      </.panel>
    </Layouts.app>
    """
  end
end
