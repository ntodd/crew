defmodule CrewWeb.DevAuthController do
  @moduledoc """
  Development only (compiled into the router only with `dev_routes`):
  signs in as a local user without GitHub. The first one is an admin.
  """
  use CrewWeb, :controller

  alias Crew.Accounts

  def create(conn, %{"login" => login}) do
    true = Application.get_env(:crew, :dev_routes, false)

    {:ok, user} =
      Accounts.sign_in_from_github(
        %{
          "id" => :erlang.phash2(login),
          "login" => login,
          "name" => String.capitalize(login),
          "avatar_url" => nil
        },
        %{access_token: nil, refresh_token: nil},
        config: %{admins: [login], allowed_users: [], allowed_org: nil}
      )

    CrewWeb.UserAuth.sign_in(conn, user)
  end
end
