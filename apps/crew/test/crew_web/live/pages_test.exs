defmodule CrewWeb.PagesTest do
  use CrewWeb.ConnCase

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "every page renders", %{conn: conn} do
      for path <- ["/", "/admin", "/admin/users", "/admin/audit"] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ "Crew", "#{path} didn't render"
      end
    end

    test "the sidebar has the admin pages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, ~s(a[href="/admin"]), "Deployment")
      assert has_element?(view, ~s(a[href="/admin/users"]), "People")
      assert has_element?(view, ~s(a[href="/admin/audit"]))
    end

    test "the dashboard shows the empty states", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#empty-boxes", "Add your first box")
      assert has_element?(view, "#empty-repos", "Install the App on a repo")
      assert has_element?(view, "#empty-jobs", "runs-on: crew-m")
    end

    test "the dashboard's activity feed updates live", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      Crew.Activity.record("box_joined", "m3max joined the fleet")
      assert render(view) =~ "m3max joined the fleet"
    end

    test "the Deployment page shows the version, deployment id and Funnel URL", %{conn: conn} do
      Crew.Settings.put("deployment_id", "ab12")
      {:ok, _} = Crew.Settings.put_public_host("crew.tail1234.ts.net")

      {:ok, view, _html} = live(conn, "/admin")
      assert render(view) =~ Crew.Config.version()
      assert has_element?(view, "#deployment-id", "ab12")
      assert has_element?(view, "#funnel-url", "https://crew.tail1234.ts.net:8443/hooks/github")
    end

    test "the Deployment page shows the release key's fingerprint", %{conn: conn} do
      {public, _} = CrewProtocol.Auth.generate_keypair()
      Application.put_env(:crew, :release_public_key, Base.encode64(public))
      on_exit(fn -> Application.delete_env(:crew, :release_public_key) end)

      {:ok, view, _html} = live(conn, "/admin")
      assert has_element?(view, "#release-fingerprint", CrewProtocol.Auth.fingerprint(public))
    end
  end

  describe "as a member" do
    setup :register_and_log_in

    test "admin pages are hidden from them", %{conn: conn} do
      for path <- ["/admin", "/admin/users", "/admin/audit", "/admin/oban"] do
        assert conn |> get(path) |> html_response(404), path
      end
    end

    test "the sidebar has no admin section", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, ~s(a[href="/admin"]))
    end
  end

  test "signed out, pages send you to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/")
  end
end
