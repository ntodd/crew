defmodule Crew.Accounts do
  @moduledoc """
  Users, sign-in and sessions.

  Users sign in with GitHub (the GitHub App's user OAuth flow). Who may
  sign in is set by config: `CREW_ADMINS`, `CREW_ALLOWED_USERS`
  and `CREW_ALLOWED_ORG`. With none of those set, the first person to
  sign in becomes the admin and nobody else gets in.
  """
  import Ecto.Query

  alias Crew.Accounts.{Session, User}
  alias Crew.{Audit, Repo, Scope}

  @session_days 30

  # -- users ---------------------------------------------------------------

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  def list_users, do: User |> order_by(:login) |> Repo.all()

  def login_config do
    %{
      admins: Application.get_env(:crew, :admins, []),
      allowed_users: Application.get_env(:crew, :allowed_users, []),
      allowed_org: Application.get_env(:crew, :allowed_org)
    }
  end

  @doc """
  Signs a GitHub user in, creating or updating their record and storing
  their tokens. `org_member?` says whether they're an active member of
  the allowed org (the caller asks GitHub).
  """
  @spec sign_in_from_github(map(), map(), keyword()) ::
          {:ok, User.t()} | {:error, :not_allowed | :disabled | Ecto.Changeset.t()}
  def sign_in_from_github(profile, tokens, opts) do
    config = Keyword.get_lazy(opts, :config, &login_config/0)
    org_member? = Keyword.get(opts, :org_member?, false)
    login = profile["login"]
    existing = find_github_user(profile["id"], login)

    cond do
      existing && existing.disabled_at ->
        {:error, :disabled}

      not allowed?(login, existing, config, org_member?) ->
        {:error, :not_allowed}

      true ->
        attrs =
          Map.merge(token_attrs(tokens), %{
            github_id: profile["id"],
            login: login,
            name: profile["name"],
            avatar_url: profile["avatar_url"],
            github_login_expired: false
          })

        Repo.transact(fn ->
          release_login(login, profile["id"])

          result =
            (existing || %User{role: initial_role(login, config)})
            |> User.github_changeset(attrs)
            |> Ecto.Changeset.change(role: role_for(existing, login, config))
            |> Repo.insert_or_update()

          with {:ok, user} <- result do
            Audit.log(user, "user.sign_in", user)
            {:ok, user}
          end
        end)
    end
  end

  # GitHub logins can be renamed and then taken by someone else, so a
  # login only identifies a record that has no GitHub id yet.
  defp find_github_user(github_id, login) do
    Repo.get_by(User, github_id: github_id) ||
      Repo.one(from u in User, where: u.login == ^login and is_nil(u.github_id))
  end

  # Another account held this login before a rename on GitHub. Its record
  # keeps its GitHub id and gets a placeholder login until its owner signs
  # in under their new name.
  defp release_login(login, github_id) do
    from(u in User, where: u.login == ^login and u.github_id != ^github_id)
    |> Repo.all()
    |> Enum.each(fn stale ->
      stale |> Ecto.Changeset.change(login: "#{login}-#{stale.github_id}") |> Repo.update!()
    end)
  end

  # Everyone has to be configured or in the allowed org. Admins promoted
  # in the UI count as configured while neither CREW_ADMINS nor an org
  # is set (the UI is where admins are managed then); with an org, leaving
  # it ends an admin's access like anyone else's.
  # With nothing configured, the first person claims the deployment and
  # only existing users get back in.
  defp allowed?(login, existing, config, org_member?) do
    cond do
      listed?(login, config, org_member?) -> true
      ui_admin?(existing, config) -> true
      unconfigured?(config) -> existing != nil or no_users?()
      true -> false
    end
  end

  defp listed?(login, config, org_member?) do
    listed_in?(login, config.admins) or listed_in?(login, config.allowed_users) or
      (config.allowed_org != nil and org_member? == true)
  end

  # GitHub logins aren't case-sensitive, and the configured lists are
  # typed by hand.
  defp listed_in?(login, list) do
    login = String.downcase(login)
    Enum.any?(list, &(String.downcase(&1) == login))
  end

  defp ui_admin?(existing, config) do
    config.admins == [] and is_nil(config.allowed_org) and
      match?(%User{role: "admin"}, existing)
  end

  defp unconfigured?(config),
    do: config.admins == [] and config.allowed_users == [] and is_nil(config.allowed_org)

  defp no_users?, do: not Repo.exists?(User)

  @doc """
  Whether a signed-in user may still use Crew, by the same rule as
  sign-in: `:allowed`, `:denied`, or `:ask_org` when it comes down to
  whether they're still an active member of the allowed org.
  """
  @spec access(User.t(), map()) :: :allowed | :denied | :ask_org
  def access(%User{} = user, config \\ login_config()) do
    cond do
      user.disabled_at -> :denied
      allowed?(user.login, user, config, false) -> :allowed
      config.allowed_org -> :ask_org
      true -> :denied
    end
  end

  @doc """
  Ends a user's access after they've left the org or an allowlist: their
  sessions and open pages end, and their GitHub tokens are dropped. The account isn't disabled;
  if they're let back in, they sign in again as before.
  """
  def revoke_access(%User{id: id} = user, reason) do
    from(u in User, where: u.id == ^id)
    |> Repo.update_all(
      set: [
        github_login_expired: true,
        access_token: nil,
        refresh_token: nil,
        updated_at: DateTime.utc_now()
      ]
    )

    delete_user_sessions(user)
    disconnect_live_views(user)
    Audit.log(nil, "user.access_revoked", user, %{"reason" => reason})
    :ok
  end

  defp initial_role(login, config) do
    cond do
      listed_in?(login, config.admins) ->
        "admin"

      config.admins == [] and not Repo.exists?(from u in User, where: u.role == "admin") ->
        "admin"

      true ->
        "member"
    end
  end

  # Configured admins are always admins; otherwise a user keeps the role
  # an admin gave them.
  defp role_for(nil, login, config), do: initial_role(login, config)

  defp role_for(%User{role: role}, login, config),
    do: if(listed_in?(login, config.admins), do: "admin", else: role)

  defp token_attrs(tokens) do
    now = DateTime.utc_now()

    %{
      access_token: tokens[:access_token],
      access_token_expires_at: tokens[:expires_in] && DateTime.add(now, tokens[:expires_in]),
      refresh_token: tokens[:refresh_token],
      refresh_token_expires_at:
        tokens[:refresh_token_expires_in] && DateTime.add(now, tokens[:refresh_token_expires_in])
    }
  end

  @doc "Stores refreshed GitHub tokens."
  def update_tokens(%User{} = user, tokens) do
    user
    |> User.github_changeset(Map.put(token_attrs(tokens), :github_login_expired, false))
    |> Repo.update()
  end

  @doc """
  Marks a user's GitHub login as expired: their refresh token no longer
  works. Returns `:stale` without changing anything if the record changed
  since `user` was read (they signed in again meanwhile), so fresh tokens
  aren't wiped.
  """
  def mark_github_login_expired(%User{id: id, updated_at: updated_at}) do
    {count, _} =
      from(u in User, where: u.id == ^id and u.updated_at == ^updated_at)
      |> Repo.update_all(
        set: [
          github_login_expired: true,
          access_token: nil,
          refresh_token: nil,
          updated_at: DateTime.utc_now()
        ]
      )

    if count == 1, do: :ok, else: :stale
  end

  @doc "Records that the user's access was checked (§18.1's six-hourly re-check)."
  def mark_access_checked(%User{id: id}) do
    from(u in User, where: u.id == ^id)
    |> Repo.update_all(set: [access_checked_at: DateTime.utc_now()])

    :ok
  end

  def set_role(%Scope{} = scope, %User{} = user, role) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      scope.user.id == user.id -> {:error, :self}
      true -> update_role(scope, user, %{role: role})
    end
  end

  def set_disabled(%Scope{} = scope, %User{} = user, disabled?) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      scope.user.id == user.id -> {:error, :self}
      true -> update_role(scope, user, %{disabled_at: if(disabled?, do: DateTime.utc_now())})
    end
  end

  defp update_role(scope, user, attrs) do
    with {:ok, updated} <- user |> User.role_changeset(attrs) |> Repo.update() do
      if updated.disabled_at, do: delete_user_sessions(updated)
      disconnect_live_views(updated)
      Audit.log(scope, "user.role", updated, Map.new(attrs, fn {k, v} -> {k, to_string(v)} end))
      {:ok, updated}
    end
  end

  # Open LiveViews hold the scope they mounted with. `:access_changed`
  # makes each one reload its page (see `CrewWeb.UserAuth`), and the
  # disconnect drops the sockets too, so they come back with the user's
  # current role, or not at all.
  defp disconnect_live_views(%User{id: id}) do
    Phoenix.PubSub.broadcast(Crew.PubSub, "user:#{id}", :access_changed)
    Phoenix.Channel.Server.broadcast(Crew.PubSub, "user_sessions:#{id}", "disconnect", %{})
  end

  # -- sessions --------------------------------------------------------------

  @doc "Creates a session and returns its token. Only the token's hash is stored."
  def create_session(%User{} = user, user_agent) do
    raw = :crypto.strong_rand_bytes(32)

    Repo.insert!(%Session{
      user_id: user.id,
      token_hash: :crypto.hash(:sha256, raw),
      user_agent: user_agent && String.slice(user_agent, 0, 255),
      last_seen_at: DateTime.utc_now()
    })

    Base.url_encode64(raw, padding: false)
  end

  def get_user_by_session(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} ->
        cutoff = DateTime.add(DateTime.utc_now(), -@session_days * 86_400)

        from(s in Session,
          join: u in assoc(s, :user),
          where:
            s.token_hash == ^:crypto.hash(:sha256, raw) and s.inserted_at > ^cutoff and
              is_nil(u.disabled_at),
          select: u
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  def get_user_by_session(_), do: nil

  def delete_session(token) when is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false) do
      Repo.delete_all(from s in Session, where: s.token_hash == ^:crypto.hash(:sha256, raw))
    end

    :ok
  end

  def delete_session(_), do: :ok

  def delete_user_sessions(%User{id: id}) do
    Repo.delete_all(from s in Session, where: s.user_id == ^id)
    :ok
  end
end
