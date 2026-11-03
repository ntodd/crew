defmodule CrewWeb.RepoLive.Index do
  @moduledoc "Repos the App is installed on (§17.3), the ones the person can read."
  use CrewWeb, :live_view

  alias Crew.Repos

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    repos =
      case Repos.readable_ids(scope) do
        :all -> Repos.list()
        ids -> Enum.filter(Repos.list(), &(&1.id in ids))
      end

    {:ok, assign(socket, page_title: "Repos", repos: repos)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Repos</:breadcrumb>
      <.header>
        Repos
        <:subtitle>The repos the GitHub App is installed on.</:subtitle>
      </.header>

      <.panel id="repos-panel" padded={false}>
        <ul class="divide-y divide-line">
          <li
            :for={repo <- @repos}
            id={"repo-#{repo.id}"}
            class="flex items-center gap-3 px-5 py-3 text-sm"
          >
            <.link
              navigate={~p"/repos/#{repo.id}"}
              class="min-w-0 flex-1 truncate font-medium text-ink hover:underline"
            >
              {repo.full_name}
            </.link>
            <.badge :if={not repo.private} size="sm">Public</.badge>
            <.badge :if={not repo.enabled} color="amber" size="sm">Disabled</.badge>
            <.badge :if={repo.priority != 0} color="sky" size="sm">Priority {repo.priority}</.badge>
          </li>
        </ul>
        <.empty_state :if={@repos == []} id="repos-empty" icon="hero-code-bracket">
          Install the App on a repo, and it shows up here.
        </.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
