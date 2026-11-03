defmodule CrewWeb.SetupController do
  @moduledoc """
  First-run setup (§6.1): the tailnet host name, then the GitHub App,
  created from Crew's manifest in one click on GitHub, then installed.
  Guarded by the one-time setup token from the boot log until the App
  exists.
  """
  use CrewWeb, :controller

  alias Crew.{GitHub, Settings, Setup}

  plug :require_setup when action in [:show, :verify, :github, :callback]

  def show(conn, _params) do
    render(conn, :show,
      page_title: "Set up Crew",
      verified: get_session(conn, :setup_ok) == true,
      host: Settings.public_host() || ""
    )
  end

  def verify(conn, %{"token" => token}) when is_binary(token) do
    with {:allow, _} <- Crew.RateLimit.hit("setup:#{remote_ip(conn)}", 60_000, 10),
         true <- Setup.verify(String.trim(token)) do
      conn |> put_session(:setup_ok, true) |> redirect(to: ~p"/setup")
    else
      _ ->
        conn
        |> put_flash(:error, "That setup token isn't right. It's in the control plane's log.")
        |> redirect(to: ~p"/setup")
    end
  end

  def verify(conn, _params), do: redirect(conn, to: ~p"/setup")

  def github(conn, params) do
    with true <- get_session(conn, :setup_ok) == true,
         {:ok, host} <- Settings.put_public_host(to_string(params["host"])) do
      deployment_id = Settings.ensure_deployment_id()
      state = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      org = params["org"] |> to_string() |> String.trim()

      web = Crew.GitHub.Client.web_url()

      action =
        if org != "" and Regex.match?(~r/\A[A-Za-z0-9-]{1,39}\z/, org),
          do: "#{web}/organizations/#{org}/settings/apps/new?state=#{state}",
          else: "#{web}/settings/apps/new?state=#{state}"

      conn
      |> put_session(:manifest_state, state)
      |> render(:github,
        page_title: "Create the GitHub App",
        action: action,
        manifest: JSON.encode!(GitHub.manifest(host, deployment_id))
      )
    else
      false ->
        redirect(conn, to: ~p"/setup")

      {:error, message} ->
        conn |> put_flash(:error, "The tailnet host #{message}.") |> redirect(to: ~p"/setup")
    end
  end

  def callback(conn, %{"code" => code, "state" => state})
      when is_binary(code) and is_binary(state) do
    expected = get_session(conn, :manifest_state)

    with true <- get_session(conn, :setup_ok) == true,
         true <- is_binary(expected) and Plug.Crypto.secure_compare(state, expected),
         {:ok, app} <- GitHub.complete_manifest(code) do
      conn
      |> delete_session(:manifest_state)
      |> put_flash(
        :info,
        "Created the GitHub App. Now install it on the repos that should run jobs on Crew."
      )
      |> redirect(external: "#{app["html_url"]}/installations/new")
    else
      _ ->
        conn
        |> put_flash(:error, "Couldn't finish creating the GitHub App. Try again.")
        |> redirect(to: ~p"/setup")
    end
  end

  def callback(conn, _params), do: redirect(conn, to: ~p"/setup")

  # GitHub sends people here after installing the App. The installation
  # webhook picks the repos up too; the sync makes sure of it.
  def installed(conn, _params) do
    Oban.insert(Crew.Repos.SyncWorker.new(%{}))

    conn
    |> put_flash(:info, "Installed. Sign in to continue.")
    |> redirect(to: ~p"/sign-in")
  end

  defp require_setup(conn, _opts) do
    if Setup.needed?(), do: conn, else: conn |> redirect(to: ~p"/sign-in") |> halt()
  end

  defp remote_ip(conn), do: CrewWeb.ClientIP.from_conn(conn)
end
