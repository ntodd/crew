defmodule Crew.Repos.AccessWorker do
  @moduledoc """
  Refreshes members' repo access (§18.3): one user at sign-in, and every
  member with a live session every 30 minutes. Admins see everything,
  so theirs isn't fetched.
  """
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 300, keys: [:user_id]]

  import Ecto.Query

  alias Crew.Accounts.{Session, User}
  alias Crew.{Repo, Repos}

  @impl true
  def perform(%{args: %{"user_id" => id}}) do
    case Repo.get(User, id) do
      %User{role: "member", disabled_at: nil} = user -> refresh(user)
      _ -> :ok
    end
  end

  def perform(_job) do
    members =
      Repo.all(
        from u in User,
          as: :user,
          where:
            u.role == "member" and is_nil(u.disabled_at) and
              exists(from s in Session, where: s.user_id == parent_as(:user).id)
      )

    for user <- members, do: %{user_id: user.id} |> new() |> Oban.insert()
    :ok
  end

  defp refresh(user) do
    case Repos.refresh_access(user) do
      :ok -> :ok
      {:error, :login_expired} -> :ok
      error -> error
    end
  end
end
