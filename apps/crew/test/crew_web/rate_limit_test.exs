defmodule CrewWeb.RateLimitTest do
  @moduledoc """
  The documented deployment puts the control plane on 127.0.0.1 behind
  `tailscale serve`, so every request arrives from the same peer
  address. Rate limits must not turn into one bucket for everybody.
  """
  use CrewWeb.ConnCase

  # A fresh tailnet address per test, so buckets don't leak between tests.
  defp client, do: "100.64.#{:rand.uniform(250)}.#{:rand.uniform(250)}"

  describe "sign-in" do
    setup do
      Application.put_env(:crew, :github_app, %{
        app_id: "1",
        client_id: "Iv1.abc",
        client_secret: "s",
        private_key: "k"
      })

      on_exit(fn -> Application.delete_env(:crew, :github_app) end)
    end

    defp callback(conn, forwarded) do
      conn = conn |> put_req_header("x-forwarded-for", forwarded) |> get(~p"/auth/github")
      state = get_session(conn, :oauth_state)

      conn
      |> recycle()
      |> put_req_header("x-forwarded-for", forwarded)
      |> get(~p"/auth/github/callback", %{"code" => "c", "state" => state})
    end

    test "is limited per client behind the proxy, not for everyone at once", %{conn: conn} do
      Crew.GitHubStub.stub(%{
        {"POST", "/login/oauth/access_token"} => {200, %{"error" => "bad_verification_code"}}
      })

      busy = client()

      for _ <- 1..20, do: callback(conn, busy)
      assert Phoenix.Flash.get(callback(conn, busy).assigns.flash, :error) =~ "Too many"

      refute Phoenix.Flash.get(callback(build_conn(), client()).assigns.flash, :error) =~
               "Too many"
    end

    test "a state that isn't a string is refused, not a crash", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")

      conn =
        conn
        |> recycle()
        |> get("/auth/github/callback?code=c&state[]=x")

      assert redirected_to(conn) == "/sign-in"
    end
  end
end
