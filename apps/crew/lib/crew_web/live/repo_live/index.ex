defmodule CrewWeb.RepoLive.Index do
  @moduledoc """
  Repos the App is installed on (§17.3), the ones the person can read,
  with filters kept in the URL. The list is loaded once and isn't paged,
  so the filters run over it in memory; paging would move them into the
  `Repos.list` query.
  """
  use CrewWeb, :live_view

  alias Crew.Repos

  @filters ~w(q state visibility priority)
  @choices %{"state" => ~w(enabled disabled), "visibility" => ~w(public private)}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    repos =
      case Repos.readable_ids(scope) do
        :all -> Repos.list()
        ids -> Enum.filter(Repos.list(), &(&1.id in ids))
      end

    {:ok, assign(socket, page_title: "Repos", all_repos: repos)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = clean(params)
    {:noreply, assign(socket, filters: filters, repos: filter(socket.assigns.all_repos, filters))}
  end

  @impl true
  def handle_event("filter", params, socket),
    do: {:noreply, push_patch(socket, to: repos_path(clean(params)))}

  # The filters in `params` that filter: the search trimmed, a choice
  # only when it's one the list knows, the priority toggle only when on.
  defp clean(params) do
    params
    |> Map.take(@filters)
    |> Map.filter(fn {_k, v} -> is_binary(v) end)
    |> Map.update("q", "", &String.trim/1)
    |> Map.filter(fn
      {"q", q} -> q != ""
      {"priority", v} -> v == "true"
      {k, v} -> v in @choices[k]
    end)
  end

  defp filter(repos, filters), do: Enum.filter(repos, &matches?(&1, filters))

  defp matches?(repo, filters) do
    Enum.all?(filters, fn
      {"q", q} -> String.contains?(String.downcase(repo.full_name), String.downcase(q))
      {"state", state} -> repo.enabled == (state == "enabled")
      {"visibility", visibility} -> repo.private == (visibility == "private")
      {"priority", "true"} -> repo.priority != 0
    end)
  end

  # The count beside the filters, which a screen reader reads out as the
  # list changes under them.
  defp count(_repos, all, filters) when filters == %{}, do: repos(length(all))

  defp count(repos, all, _filters),
    do: "#{length(repos)} of #{repos(length(all))}"

  defp repos(1), do: "1 repo"
  defp repos(n), do: "#{n} repos"

  defp repos_path(filters) when filters == %{}, do: ~p"/repos"
  defp repos_path(filters), do: ~p"/repos?#{filters}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Repos</:breadcrumb>
      <.header class="pb-0">
        Repos
        <:subtitle>The repos the GitHub App is installed on.</:subtitle>
      </.header>

      <div class="space-y-3">
        <.form
          :if={@all_repos != []}
          for={%{}}
          id="repo-filters"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-wrap items-center gap-2"
        >
          <.toolbar_search
            id="repo-search"
            value={@filters["q"]}
            placeholder="Search repos"
            label="Search repos by name"
          />
          <.toolbar_select
            name="state"
            label="State"
            value={@filters["state"]}
            class="w-full sm:w-36"
            options={[{"Any state", ""}, {"Enabled", "enabled"}, {"Disabled", "disabled"}]}
          />
          <.toolbar_select
            name="visibility"
            label="Visibility"
            value={@filters["visibility"]}
            class="w-full sm:w-36"
            options={[{"Any visibility", ""}, {"Public", "public"}, {"Private", "private"}]}
          />
          <.toolbar_check
            name="priority"
            label="Has a priority"
            checked={@filters["priority"] == "true"}
          />
          <p id="repo-count" role="status" class="ml-auto px-1.5 text-xs tabular-nums text-ink-3">
            {count(@repos, @all_repos, @filters)}
          </p>
        </.form>

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
              <.badge :if={repo.priority != 0} color="sky" size="sm">
                Priority {repo.priority}
              </.badge>
            </li>
          </ul>
          <.empty_state :if={@all_repos == []} id="repos-empty" icon="hero-code-bracket">
            Install the App on a repo, and it shows up here.
          </.empty_state>
          <.empty_state
            :if={@all_repos != [] and @repos == []}
            id="repos-no-match"
            icon="hero-funnel"
          >
            No repos match these filters.
            <:action>
              <.button size="sm" variant="secondary" patch={~p"/repos"}>Clear filters</.button>
            </:action>
          </.empty_state>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
