defmodule CrewWeb.AuthControllerTest do
  use CrewWeb.ConnCase

  setup do
    Application.put_env(:crew, :github_app, %{
      app_id: "1",
      client_id: "Iv1.abc",
      client_secret: "s",
      private_key: "k"
    })

    Application.put_env(:crew, :admins, ["mona"])

    on_exit(fn ->
      Application.delete_env(:crew, :github_app) && Application.delete_env(:crew, :admins)
    end)
  end

  test "redirects to GitHub with state and a PKCE challenge", %{conn: conn} do
    conn = get(conn, ~p"/auth/github")
    location = redirected_to(conn, 302)
    assert location =~ "https://github.com/login/oauth/authorize?"
    query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert query["client_id"] == "Iv1.abc"
    assert query["code_challenge_method"] == "S256"
    assert query["state"] == get_session(conn, :oauth_state)
  end

  test "signs in on a matching callback", %{conn: conn} do
    conn = get(conn, ~p"/auth/github")
    state = get_session(conn, :oauth_state)
    verifier = get_session(conn, :oauth_verifier)

    Crew.GitHubStub.stub(%{
      {"POST", "/login/oauth/access_token"} => fn conn ->
        form = Crew.GitHubStub.body(conn)
        assert form["code"] == "the-code"
        assert form["code_verifier"] == verifier

        Crew.GitHubStub.json(conn, 200, %{
          "access_token" => "ghu_x",
          "refresh_token" => "ghr_y",
          "expires_in" => 28_800,
          "refresh_token_expires_in" => 1_000_000
        })
      end,
      {"GET", "/user"} => {200, %{"id" => 1, "login" => "mona", "name" => "Mona"}}
    })

    conn =
      conn
      |> recycle()
      |> get(~p"/auth/github/callback", %{"code" => "the-code", "state" => state})

    assert redirected_to(conn) == "/"
    assert get_session(conn, :session_token)
  end

  test "refuses a callback whose state doesn't match", %{conn: conn} do
    conn = get(conn, ~p"/auth/github")

    conn =
      conn |> recycle() |> get(~p"/auth/github/callback", %{"code" => "c", "state" => "forged"})

    assert redirected_to(conn) == "/sign-in"
    refute get_session(conn, :session_token)
  end

  test "pages need a session", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == "/sign-in"
    assert redirected_to(get(build_conn(), ~p"/admin")) == "/sign-in"
  end

  test "admin pages are hidden from members", %{conn: conn} do
    conn = log_in(conn, user_fixture())
    assert conn |> get(~p"/admin") |> html_response(404)
    assert conn |> get(~p"/admin/oban") |> html_response(404)
  end

  test "pages carry a strict content security policy", %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src 'self'"
    assert csp =~ "frame-ancestors 'none'"
    refute csp =~ "unsafe-eval"
  end
end
