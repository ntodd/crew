defmodule Crew.Repos do
  @moduledoc """
  Installations, repos and their settings (§7.4), and members' repo
  access (§18.3).

  Repos are synced from the App's installations, on a timer and on the
  `installation` and `installation_repositories` webhooks. A repo that
  leaves an installation (or whose installation is deleted) is archived,
  never deleted: its jobs and runs keep their history.
  """
  import Ecto.Query

  require Logger

  alias Crew.{Audit, GitHub, Repo, Scope}
  alias Crew.GitHub.Client
  alias Crew.Repos.{Access, Installation}
  alias Crew.Repos.Repo, as: GitRepo

  @settings_topic "repo_settings"
  # §18.3: on an error, the last known result is kept this long.
  @access_ttl_s 6 * 3600

  # -- reads --------------------------------------------------------------------

  def list_installations(opts \\ []) do
    query = from i in Installation, order_by: i.account_login

    query =
      if Keyword.get(opts, :all, false), do: query, else: where(query, [i], is_nil(i.removed_at))

    Repo.all(query)
  end

  def get_installation_by_github_id(id), do: Repo.get_by(Installation, github_id: id)

  @doc "Repos that aren't archived, by name."
  def list do
    Repo.all(from r in GitRepo, where: is_nil(r.archived_at), order_by: r.full_name)
  end

  def get(id), do: Repo.get(GitRepo, id)
  def get!(id), do: Repo.get!(GitRepo, id)
  def get_by_full_name(name), do: Repo.get_by(GitRepo, full_name: name)
  def get_by_github_id(id), do: Repo.get_by(GitRepo, github_id: id)

  def with_installation(%GitRepo{} = repo), do: Repo.preload(repo, :installation)

  # -- installations ---------------------------------------------------------

  @doc "Creates or updates an installation from GitHub's representation of it."
  def upsert_installation(%{"id" => github_id} = data) do
    account = data["account"] || %{}

    attrs = %{
      github_id: github_id,
      account_login: account["login"],
      account_type: account["type"] || "User",
      account_id: account["id"],
      permissions: data["permissions"] || %{},
      suspended_at: parse_time(data["suspended_at"]),
      removed_at: nil
    }

    (get_installation_by_github_id(github_id) || %Installation{})
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert_or_update()
  end

  def set_suspended(github_id, suspended?) do
    case get_installation_by_github_id(github_id) do
      nil ->
        {:error, :not_found}

      i ->
        i
        |> Ecto.Changeset.change(suspended_at: if(suspended?, do: DateTime.utc_now()))
        |> Repo.update()
    end
  end

  @doc "The App was uninstalled: the installation is marked removed and its repos archived."
  def installation_removed(github_id) do
    with %Installation{} = i <- get_installation_by_github_id(github_id) do
      now = DateTime.utc_now()

      Repo.transact(fn ->
        i |> Ecto.Changeset.change(removed_at: now) |> Repo.update!()

        Repo.update_all(
          from(r in GitRepo, where: r.installation_id == ^i.id and is_nil(r.archived_at)),
          set: [archived_at: now, updated_at: now]
        )

        {:ok, :done}
      end)
    end

    :ok
  end

  @doc "`installation_repositories` added: upsert them (fetching an installation Crew hasn't seen)."
  def repos_added(_installation_github_id, []), do: :ok

  def repos_added(installation_github_id, repos) do
    with {:ok, i} <- ensure_installation(installation_github_id) do
      Enum.each(repos, &upsert_repo(i, &1))
      :ok
    end
  end

  @doc "`installation_repositories` removed: archive them."
  def repos_removed(installation_github_id, repos) do
    with %Installation{} = i <- get_installation_by_github_id(installation_github_id) do
      ids = Enum.map(repos, & &1["id"])
      now = DateTime.utc_now()

      Repo.update_all(
        from(r in GitRepo, where: r.installation_id == ^i.id and r.github_id in ^ids),
        set: [archived_at: now, updated_at: now]
      )
    end

    :ok
  end

  @doc """
  The repo a webhook is about. A repo the App was just given (before the
  `installation_repositories` event or a sync got here) is added; an
  installation Crew hasn't seen is fetched first.
  """
  def ensure_from_payload(%{"repository" => %{"id" => github_id} = data} = payload) do
    result =
      case get_by_github_id(github_id) do
        %GitRepo{} = repo ->
          {:ok, repo}

        nil ->
          with {:ok, installation} <- ensure_installation(get_in(payload, ["installation", "id"])),
               do: upsert_repo(installation, data)
      end

    with {:ok, repo} <- result, do: {:ok, repo |> touch_activity() |> Repo.preload(:installation)}
  end

  def ensure_from_payload(_payload), do: {:error, :no_repository}

  # The reconciler skips repos whose webhooks are flowing (§8.8). One
  # write every 30 s at most, however busy the repo.
  defp touch_activity(%GitRepo{last_activity_at: at} = repo) do
    now = DateTime.utc_now()

    if is_nil(at) or DateTime.diff(now, at) >= 30 do
      Repo.update_all(from(r in GitRepo, where: r.id == ^repo.id), set: [last_activity_at: now])
      %{repo | last_activity_at: now}
    else
      repo
    end
  end

  defp ensure_installation(nil), do: {:error, :no_installation}

  defp ensure_installation(github_id) do
    case get_installation_by_github_id(github_id) do
      %Installation{} = i ->
        {:ok, i}

      nil ->
        with {:ok, data} <- Client.get_installation(GitHub.app(), github_id),
             do: upsert_installation(data)
    end
  end

  # -- sync --------------------------------------------------------------------------

  @doc """
  Syncs every installation of the App and its repos. Installations no
  longer listed are marked removed. Returns the number of live repos.
  """
  def sync_all do
    with app when is_map(app) <- GitHub.app() || {:error, :not_configured},
         {:ok, installations} <- Client.list_installations(app) do
      synced =
        for data <- installations do
          {:ok, installation} = upsert_installation(data)
          {installation, sync_installation(installation)}
        end

      listed = MapSet.new(installations, & &1["id"])

      for i <- list_installations(),
          not MapSet.member?(listed, i.github_id),
          do: installation_removed(i.github_id)

      {:ok, synced |> Enum.map(fn {_, n} -> n end) |> Enum.sum()}
    end
  end

  @doc "Syncs one installation's repos. Returns how many it has."
  def sync_installation(%Installation{} = installation) do
    case Client.list_installation_repos(installation.github_id, class: :normal) do
      {:ok, repos} ->
        Enum.each(repos, &upsert_repo(installation, &1))
        listed = Enum.map(repos, & &1["id"])
        now = DateTime.utc_now()

        Repo.update_all(
          from(r in GitRepo,
            where:
              r.installation_id == ^installation.id and r.github_id not in ^listed and
                is_nil(r.archived_at)
          ),
          set: [archived_at: now, updated_at: now]
        )

        installation |> Ecto.Changeset.change(synced_at: now) |> Repo.update!()
        Enum.count(repos, &(&1["archived"] != true))

      error ->
        Logger.warning(
          "syncing installation #{installation.account_login} failed: #{inspect(error)}"
        )

        0
    end
  end

  defp upsert_repo(installation, data) do
    archived_at =
      if data["archived"] == true, do: DateTime.utc_now(), else: nil

    attrs = %{
      installation_id: installation.id,
      github_id: data["id"],
      full_name: data["full_name"],
      private: Map.get(data, "private", true),
      default_branch: data["default_branch"] || "main",
      archived_at: archived_at
    }

    (get_by_github_id(data["id"]) || %GitRepo{})
    |> GitRepo.github_changeset(attrs)
    |> Repo.insert_or_update()
  end

  # -- permissions ---------------------------------------------------------------

  @levels %{"none" => 0, "read" => 1, "write" => 2, "admin" => 3}

  # Organization permissions: GitHub doesn't grant these to an installation
  # on a personal account, so they're never missing there.
  @org_permissions ~w(members)

  @doc "The permissions Crew needs that the installation didn't grant (§6.1)."
  def missing_permissions(%Installation{permissions: granted, account_type: type}) do
    granted = granted || %{}

    for {perm, needed} <- Enum.sort(GitHub.required_permissions()),
        type == "Organization" or perm not in @org_permissions,
        Map.get(@levels, granted[perm], 0) < @levels[needed],
        do: {perm, needed}
  end

  # -- settings (§7.4) -------------------------------------------------------------

  def subscribe_settings, do: Phoenix.PubSub.subscribe(Crew.PubSub, @settings_topic)

  def change_settings(%GitRepo{} = repo, attrs \\ %{}),
    do: GitRepo.settings_changeset(repo, attrs, size_names())

  def update_settings(%Scope{} = scope, %GitRepo{} = repo, attrs) do
    if Scope.admin?(scope) do
      changeset = GitRepo.settings_changeset(repo, attrs, size_names())

      with {:ok, updated} <- Repo.update(changeset) do
        Audit.log(scope, "repo.settings", updated, stringify(changeset.changes))

        Phoenix.PubSub.broadcast(
          Crew.PubSub,
          @settings_topic,
          {:repo_settings_changed, updated.id}
        )

        {:ok, updated}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp size_names, do: Enum.map(Crew.Sizes.list(), & &1.name)

  defp stringify(changes), do: Map.new(changes, fn {k, v} -> {to_string(k), v} end)

  # -- access (§18.3) ----------------------------------------------------------------

  @doc "Whether the scope's user can read the repo: admins always; members from their GitHub access."
  def can_read?(%Scope{} = scope, repo_id) do
    Scope.admin?(scope) or access_row(scope, repo_id) != nil
  end

  @doc "Whether they can act on its runs (cancel, re-run)."
  def can_push?(%Scope{} = scope, repo_id) do
    case access_row(scope, repo_id) do
      %Access{can_push: true} -> true
      _ -> Scope.admin?(scope)
    end
  end

  defp access_row(scope, repo_id) do
    case Scope.user_id(scope) do
      nil ->
        nil

      user_id ->
        Repo.one(
          from a in Access,
            where: a.user_id == ^user_id and a.repo_id == ^repo_id and a.checked_at > ^cutoff()
        )
    end
  end

  @doc "The ids of the repos the scope can read, or `:all` for admins."
  def readable_ids(%Scope{} = scope) do
    if Scope.admin?(scope) do
      :all
    else
      case Scope.user_id(scope) do
        nil ->
          []

        user_id ->
          Repo.all(
            from a in Access,
              where: a.user_id == ^user_id and a.checked_at > ^cutoff(),
              select: a.repo_id
          )
      end
    end
  end

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -@access_ttl_s)

  @doc """
  Refreshes a user's repo access from their GitHub token, installation by
  installation. An installation GitHub couldn't answer for keeps its
  rows until they lapse. When repos are dropped, the user's open pages
  are told (`{:repo_access_changed, repo_ids}` on `user:<id>`).
  """
  def refresh_access(%Crew.Accounts.User{} = user) do
    with {:ok, token} <- GitHub.user_token(user) do
      results =
        for installation <- list_installations() do
          {installation, Client.user_installation_repos(token, installation.github_id)}
        end

      removed =
        Enum.flat_map(results, fn
          {installation, {:ok, repos}} -> store_access(user, installation, repos)
          _ -> []
        end)

      if removed != [],
        do:
          Phoenix.PubSub.broadcast(
            Crew.PubSub,
            "user:#{user.id}",
            {:repo_access_changed, removed}
          )

      case Enum.find(results, &match?({_, {:error, _}}, &1)) do
        nil -> :ok
        {_, error} -> error
      end
    end
  end

  defp store_access(user, installation, repos) do
    now = DateTime.utc_now()
    by_github_id = Map.new(repos, &{&1["id"], get_in(&1, ["permissions", "push"]) == true})

    ours =
      Repo.all(
        from r in GitRepo,
          where: r.installation_id == ^installation.id,
          select: {r.id, r.github_id}
      )

    {granted, denied} = Enum.split_with(ours, fn {_, gid} -> Map.has_key?(by_github_id, gid) end)

    rows =
      for {id, gid} <- granted,
          do: %{user_id: user.id, repo_id: id, can_push: by_github_id[gid], checked_at: now}

    Repo.insert_all(Access, rows,
      on_conflict: {:replace, [:can_push, :checked_at]},
      conflict_target: [:user_id, :repo_id]
    )

    denied_ids = Enum.map(denied, &elem(&1, 0))

    {_, removed} =
      Repo.delete_all(
        from(a in Access,
          where: a.user_id == ^user.id and a.repo_id in ^denied_ids,
          select: a.repo_id
        )
      )

    removed
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
