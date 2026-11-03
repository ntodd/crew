defmodule CrewWeb.SetupControllerTest do
  use CrewWeb.ConnCase

  import Ecto.Query

  alias Crew.{GitHubStub, Settings}

  # Setup is open only until the App exists, and only with the boot token.
  setup do
    Application.delete_env(:crew, :github_app)
    :persistent_term.put(Crew.Setup, "the-setup-token")
    on_exit(fn -> :persistent_term.erase(Crew.Setup) end)
  end

  defp verified(conn) do
    conn |> post(~p"/setup", %{"token" => "the-setup-token"}) |> recycle()
  end

  test "asks for the setup token first", %{conn: conn} do
    html = conn |> get(~p"/setup") |> html_response(200)
    assert html =~ "Setup token"
    refute html =~ "Tailnet host"
  end

  test "a wrong token is refused", %{conn: conn} do
    conn = post(conn, ~p"/setup", %{"token" => "nope"})
    assert redirected_to(conn) == ~p"/setup"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't right"
    refute get_session(conn, :setup_ok)
  end

  test "after the token, asks for the tailnet host", %{conn: conn} do
    html = conn |> verified() |> get(~p"/setup") |> html_response(200)
    assert html =~ "Tailnet host"
  end

  describe "creating the App" do
    test "stores the host and a deployment id, and posts Crew's manifest to GitHub", %{conn: conn} do
      conn =
        conn
        |> verified()
        |> post(~p"/setup/github", %{"host" => "Crew.Tail1234.ts.net.", "org" => ""})

      html = html_response(conn, 200)
      assert Settings.public_host() == "crew.tail1234.ts.net"
      id = Settings.deployment_id()
      assert CrewProtocol.Names.deployment_id?(id)

      [action] = Regex.run(~r/action="([^"]+)"/, html, capture: :all_but_first)
      assert action =~ "https://github.com/settings/apps/new?state="
      state = get_session(conn, :manifest_state)
      assert String.ends_with?(action, state)

      [json] = Regex.run(~r/name="manifest" value="([^"]+)"/, html, capture: :all_but_first)
      manifest = json |> unescape() |> Jason.decode!()

      assert manifest["name"] == "Crew (#{id})"

      assert manifest["hook_attributes"] == %{
               "url" => "https://crew.tail1234.ts.net:8443/hooks/github",
               "active" => true
             }

      assert manifest["redirect_url"] == "https://crew.tail1234.ts.net/setup/github/callback"
      assert manifest["callback_urls"] == ["https://crew.tail1234.ts.net/auth/github/callback"]
      assert manifest["setup_url"] == "https://crew.tail1234.ts.net/setup/github/installed"
      assert manifest["default_events"] == ["workflow_job", "workflow_run"]
      assert manifest["public"] == false

      assert manifest["default_permissions"] == %{
               "administration" => "write",
               "actions" => "write",
               "metadata" => "read",
               "pull_requests" => "read",
               "members" => "read"
             }
    end

    test "creates it under an organization when one is given", %{conn: conn} do
      html =
        conn
        |> verified()
        |> post(~p"/setup/github", %{"host" => "crew.tail1234.ts.net", "org" => "acme"})
        |> html_response(200)

      assert html =~ "https://github.com/organizations/acme/settings/apps/new?state="
    end

    test "keeps the deployment id it already has", %{conn: conn} do
      Settings.put("deployment_id", "ab12")

      conn
      |> verified()
      |> post(~p"/setup/github", %{"host" => "crew.tail1234.ts.net"})

      assert Settings.deployment_id() == "ab12"
    end

    test "refuses a host with a scheme or a port", %{conn: conn} do
      for host <- ["https://crew.tail1234.ts.net", "crew.tail1234.ts.net:443", "crew", ""] do
        conn =
          conn
          |> verified()
          |> post(~p"/setup/github", %{"host" => host})

        assert redirected_to(conn) == ~p"/setup", host
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "host name"
      end

      assert Settings.public_host() == nil
    end

    test "needs the setup token", %{conn: conn} do
      conn = post(conn, ~p"/setup/github", %{"host" => "crew.tail1234.ts.net"})
      assert redirected_to(conn) == ~p"/setup"
      assert Settings.public_host() == nil
    end
  end

  describe "GitHub's callback" do
    setup %{conn: conn} do
      conn =
        conn
        |> verified()
        |> post(~p"/setup/github", %{"host" => "crew.tail1234.ts.net"})

      %{conn: recycle(conn), state: get_session(conn, :manifest_state)}
    end

    test "stores the App's credentials, encrypted, and sends the admin to install it",
         %{conn: conn, state: state} do
      GitHubStub.stub(%{
        {"POST", "/app-manifests/the-code/conversions"} =>
          {201,
           %{
             "id" => 42,
             "slug" => "crew-ab12",
             "client_id" => "Iv1.abc",
             "client_secret" => "shh",
             "pem" => "-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----\n",
             "webhook_secret" => "hook-secret",
             "html_url" => "https://github.com/apps/crew-ab12"
           }}
      })

      conn = get(conn, ~p"/setup/github/callback", %{"code" => "the-code", "state" => state})
      assert redirected_to(conn) == "https://github.com/apps/crew-ab12/installations/new"

      assert Crew.GitHub.configured?()
      assert Crew.GitHub.webhook_secret() == "hook-secret"
      assert Crew.GitHub.app().client_id == "Iv1.abc"

      # Encrypted at rest: the raw row doesn't contain the secret.
      [raw] = Crew.Repo.all(from s in "settings", where: s.key == "github_app", select: s.value)
      refute raw =~ "hook-secret"
    end

    test "a state that doesn't match is refused", %{conn: conn} do
      conn = get(conn, ~p"/setup/github/callback", %{"code" => "the-code", "state" => "forged"})
      assert redirected_to(conn) == ~p"/setup"
      refute Crew.GitHub.configured?()
    end
  end

  test "once the App exists, setup is closed", %{conn: conn} do
    Application.put_env(:crew, :github_app, %{
      client_id: "a",
      client_secret: "b",
      private_key: "c"
    })

    on_exit(fn -> Application.delete_env(:crew, :github_app) end)

    assert conn |> get(~p"/setup") |> redirected_to() == ~p"/sign-in"

    assert conn |> post(~p"/setup", %{"token" => "the-setup-token"}) |> redirected_to() ==
             ~p"/sign-in"
  end

  test "GitHub's post-install redirect lands on sign-in", %{conn: conn} do
    conn = get(conn, ~p"/setup/github/installed", %{"installation_id" => "1"})
    assert redirected_to(conn) == ~p"/sign-in"
  end

  defp unescape(html) do
    html
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
