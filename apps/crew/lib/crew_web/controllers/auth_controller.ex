defmodule CrewWeb.AuthController do
  @moduledoc "Sign in with GitHub (the GitHub App's user OAuth flow, with PKCE and a state check)."
  use CrewWeb, :controller

  alias Crew.GitHub
  alias CrewWeb.UserAuth

  require Logger

  def new(conn, _params) do
    cond do
      conn.assigns.current_scope.user ->
        redirect(conn, to: ~p"/")

      Crew.Setup.needed?() ->
        redirect(conn, to: ~p"/setup")

      true ->
        render(conn, :new,
          page_title: "Sign in",
          dev_sign_in: Application.get_env(:crew, :dev_routes, false)
        )
    end
  end

  def request(conn, _params) do
    if GitHub.configured?() do
      state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      {url, verifier} = GitHub.authorize_url(state, callback_url())

      conn
      |> put_session(:oauth_state, state)
      |> put_session(:oauth_verifier, verifier)
      |> redirect(external: url)
    else
      redirect(conn, to: ~p"/setup")
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :oauth_state)
    verifier = get_session(conn, :oauth_verifier)
    conn = conn |> delete_session(:oauth_state) |> delete_session(:oauth_verifier)

    # A query string can make `code` or `state` a list or map.
    with true <-
           is_binary(code) and is_binary(state) and is_binary(expected) and
             Plug.Crypto.secure_compare(state, expected),
         {:allow, _} <- Crew.RateLimit.hit("sign-in:#{remote_ip(conn)}", 60_000, 20),
         {:ok, user} <- GitHub.complete_sign_in(code, verifier, callback_url()) do
      UserAuth.sign_in(conn, user)
    else
      false ->
        sign_in_failed(conn, "The sign-in request expired or didn't match. Try again.")

      {:deny, _} ->
        sign_in_failed(conn, "Too many sign-in attempts. Wait a minute and try again.")

      {:error, :not_allowed} ->
        sign_in_failed(conn, "That GitHub account isn't allowed to use this Crew.")

      {:error, :disabled} ->
        sign_in_failed(conn, "That account has been disabled.")

      {:error, reason} ->
        Logger.warning("GitHub sign-in failed: #{inspect(reason)}")
        sign_in_failed(conn, "GitHub sign-in failed. Try again.")
    end
  end

  def callback(conn, %{"error" => _}), do: sign_in_failed(conn, "GitHub sign-in was cancelled.")
  def callback(conn, _params), do: sign_in_failed(conn, "GitHub sign-in failed. Try again.")

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.sign_out()
  end

  defp sign_in_failed(conn, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/sign-in")
  end

  defp callback_url, do: Crew.Config.base_url() <> "/auth/github/callback"

  defp remote_ip(conn), do: CrewWeb.ClientIP.from_conn(conn)
end
