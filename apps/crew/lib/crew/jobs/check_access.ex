defmodule Crew.Jobs.CheckAccess do
  @moduledoc """
  Checks that everyone with a live session may still use Crew (they
  might have left the org or an allowlist). Token refreshes check too, but
  someone who only watches the dashboard may not refresh for weeks.

  Someone whose GitHub login has expired can't be checked against the
  org, so they're signed out when it comes down to the org; signing in
  again checks it.
  """
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 3600]

  import Ecto.Query

  alias Crew.Accounts
  alias Crew.Accounts.{Session, User}

  @impl true
  def perform(_job) do
    if Crew.GitHub.configured?() do
      config = Accounts.login_config()
      Enum.each(signed_in_users(), &check(&1, config))
    end

    :ok
  end

  defp check(user, config) do
    case Accounts.access(user, config) do
      :allowed ->
        :ok

      :denied ->
        Accounts.revoke_access(user, "no longer allowed")

      :ask_org when user.github_login_expired or is_nil(user.refresh_token) ->
        Accounts.revoke_access(user, "org membership couldn't be checked")

      :ask_org ->
        case Crew.GitHub.check_access(user) do
          # The refresh found the login dead, so the org can't be checked
          # (unless the check itself already said no and signed them out).
          {:error, :login_expired} ->
            if signed_in?(user),
              do: Accounts.revoke_access(user, "org membership couldn't be checked")

          _ ->
            :ok
        end
    end
  end

  defp signed_in?(%User{id: id}),
    do: Crew.Repo.exists?(from s in Session, where: s.user_id == ^id)

  defp signed_in_users do
    from(u in User,
      as: :user,
      where:
        is_nil(u.disabled_at) and
          exists(from s in Session, where: s.user_id == parent_as(:user).id)
    )
    |> Crew.Repo.all()
  end
end
