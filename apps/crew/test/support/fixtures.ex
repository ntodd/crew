defmodule Crew.Fixtures do
  @moduledoc "Builds records for tests."

  alias Crew.Repo

  def unique, do: System.unique_integer([:positive])

  def user_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    n = unique()

    %Crew.Accounts.User{
      login: Map.get(attrs, :login, "user#{n}"),
      github_id: Map.get(attrs, :github_id, n),
      name: Map.get(attrs, :name, "User #{n}"),
      role: Map.get(attrs, :role, "member"),
      access_token: Map.get(attrs, :access_token, "ghu_user#{n}"),
      access_token_expires_at:
        Map.get(attrs, :access_token_expires_at, DateTime.add(DateTime.utc_now(), 8 * 3600)),
      refresh_token: Map.get(attrs, :refresh_token, "ghr_user#{n}"),
      refresh_token_expires_at: DateTime.add(DateTime.utc_now(), 86_400 * 180),
      disabled_at: Map.get(attrs, :disabled_at)
    }
    |> Repo.insert!()
  end
end
