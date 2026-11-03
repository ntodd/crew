defmodule CrewWeb.ConnCase do
  @moduledoc """
  Tests that need a connection (controllers and LiveViews). See
  `Crew.DataCase` for why `async: true` only applies on Postgres.
  """

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false) and Crew.Repo.database() == "postgres"

    quote do
      use ExUnit.Case, async: unquote(async)

      @endpoint CrewWeb.Endpoint

      use CrewWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import CrewWeb.ConnCase
      import Crew.Fixtures

      setup tags do
        Crew.DataCase.setup_sandbox(tags)
        # Each test gets its own client address, so rate limits (kept in
        # ETS for the whole run) never carry over from another test.
        client = {10, :rand.uniform(254), :rand.uniform(254), :rand.uniform(254)}
        {:ok, conn: %{Phoenix.ConnTest.build_conn() | remote_ip: client}}
      end
    end
  end

  @doc "Signs `user` in on `conn`."
  def log_in(conn, user) do
    token = Crew.Accounts.create_session(user, "test")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:session_token, token)
  end

  def register_and_log_in(%{conn: conn}) do
    user = Crew.Fixtures.user_fixture()
    %{conn: log_in(conn, user), user: user}
  end

  def register_and_log_in_admin(%{conn: conn}) do
    user = Crew.Fixtures.user_fixture(role: "admin")
    %{conn: log_in(conn, user), user: user}
  end
end
