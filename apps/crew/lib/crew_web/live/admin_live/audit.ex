defmodule CrewWeb.AdminLive.Audit do
  @moduledoc "The audit log: who changed what. Secret values never appear here."
  use CrewWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Audit log") |> assign(:events, Crew.Audit.recent(300))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Audit log</:breadcrumb>
      <.header>Audit log</.header>
      <section class="overflow-x-auto rounded-xl border border-line bg-raised shadow-xs">
        <table class="w-full text-sm">
          <thead class="border-b border-line text-left text-xs text-ink-3">
            <tr>
              <th class="px-5 py-2 font-medium">When</th>
              <th class="px-3 py-2 font-medium">Who</th>
              <th class="px-3 py-2 font-medium">What</th>
              <th class="px-5 py-2 font-medium">Details</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-line">
            <tr :for={e <- @events} id={"audit-#{e.id}"}>
              <td class="whitespace-nowrap px-5 py-2 text-ink-2">
                <.local_time id={"at-#{e.id}"} at={e.inserted_at} />
              </td>
              <td class="px-3 py-2">{e.actor_login || "system"}</td>
              <td class="px-3 py-2 font-mono text-xs">{e.action}</td>
              <td class="px-5 py-2 text-xs text-ink-2">
                <span :if={e.subject_type}>{e.subject_type}</span>
                <span :for={{k, v} <- e.metadata || %{}} class="ml-2"><span class="text-ink-3">{k}=</span>{v}</span>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@events == []} class="px-5 py-6 text-sm text-ink-3">Nothing yet.</p>
      </section>
    </Layouts.app>
    """
  end
end
