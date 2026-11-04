defmodule CrewWeb.DeploymentUpdateTest do
  @moduledoc """
  The Deployment page's update panel (§20.3): the running version, the
  newest release from CREW_UPDATE_REPO, and an admin's "Update to X",
  which writes the request crew-update takes.
  """
  use CrewWeb.ConnCase

  alias Crew.GitHubStub

  @moduletag :tmp_dir

  setup :register_and_log_in_admin

  setup %{tmp_dir: dir} do
    for {key, value} <- [update_dir: dir, update_repo: "ntodd/crew", update_check: true] do
      previous = Application.fetch_env(:crew, key)
      Application.put_env(:crew, key, value)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:crew, key, v)
          :error -> Application.delete_env(:crew, key)
        end
      end)
    end

    File.mkdir_p!(Path.join(dir, "request"))
    File.mkdir_p!(Path.join(dir, "status"))
    %{dir: dir}
  end

  defp next_version do
    v = Version.parse!(Crew.Config.version())
    "#{v.major}.#{v.minor + 1}.0"
  end

  defp stub_releases(tags) do
    GitHubStub.stub(%{
      {"GET", "/repos/ntodd/crew/releases"} =>
        {200,
         for tag <- tags do
           %{
             "tag_name" => tag,
             "html_url" => "https://github.com/ntodd/crew/releases/tag/#{tag}",
             "draft" => false,
             "prerelease" => false
           }
         end}
    })
  end

  defp checked(tags) do
    stub_releases(tags)
    {:ok, _} = Crew.Updates.check()
  end

  defp install_updater(dir), do: File.write!(Path.join([dir, "status", "updater"]), "1\n")

  test "shows the running version and the newest release", %{conn: conn, dir: dir} do
    install_updater(dir)
    checked(["v" <> next_version()])

    {:ok, view, _html} = live(conn, "/admin")
    assert has_element?(view, "#crew-update", "Running Crew #{Crew.Config.version()}")
    assert has_element?(view, "#crew-update-available", "Crew #{next_version()} is available")

    assert has_element?(
             view,
             ~s(#crew-update-available a[href="https://github.com/ntodd/crew/releases/tag/v#{next_version()}"])
           )

    assert has_element?(view, "#update-crew", "Update to #{next_version()}")
  end

  test "Update to X asks the host's updater, and the page follows it", %{conn: conn, dir: dir} do
    install_updater(dir)
    checked(["v" <> next_version()])
    version = next_version()

    {:ok, view, _html} = live(conn, "/admin")
    view |> element("#update-crew") |> render_click()

    assert File.read!(Path.join([dir, "request", "version"])) == version <> "\n"

    assert has_element?(
             view,
             "#crew-update",
             "Waiting for the host's updater to pick up #{version}"
           )

    refute has_element?(view, "#update-crew")

    assert [%{action: "crew.update"}] =
             Enum.filter(Crew.Audit.recent(), &(&1.action == "crew.update"))

    # The updater takes the request and reports.
    File.rm!(Path.join([dir, "request", "version"]))

    File.write!(
      Path.join([dir, "status", "state.json"]),
      JSON.encode!(%{
        "state" => "running",
        "from" => Crew.Config.version(),
        "to" => version,
        "message" => "Pulling ghcr.io/ntodd/crew:#{version}.",
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    )

    send(view.pid, :refresh_update)
    assert has_element?(view, "#crew-update", "Pulling ghcr.io/ntodd/crew:#{version}.")
  end

  test "without the updater, says how to install it", %{conn: conn} do
    checked(["v" <> next_version()])

    {:ok, view, _html} = live(conn, "/admin")
    refute has_element?(view, "#update-crew")
    assert has_element?(view, "#install-updater-command", "/app/updater/crew-update")
    assert has_element?(view, "#install-updater-command", "install /path/to/compose.yml")
  end

  test "up to date", %{conn: conn, dir: dir} do
    install_updater(dir)
    checked(["v" <> Crew.Config.version()])

    {:ok, view, _html} = live(conn, "/admin")
    assert has_element?(view, "#crew-update", "Up to date")
    refute has_element?(view, "#update-crew")
  end

  test "the last update's outcome", %{conn: conn, dir: dir} do
    install_updater(dir)

    File.write!(
      Path.join([dir, "status", "state.json"]),
      JSON.encode!(%{
        "state" => "rolled_back",
        "message" => "0.9.0 didn't come up healthy, so 0.1.0 is back.",
        "at" => "2026-11-04T10:00:00Z"
      })
    )

    {:ok, view, _html} = live(conn, "/admin")
    assert has_element?(view, "#last-update.text-danger", "didn't come up healthy")
  end

  test "Check now asks GitHub", %{conn: conn} do
    stub_releases(["v" <> next_version()])

    {:ok, view, _html} = live(conn, "/admin")
    assert has_element?(view, "#crew-update", "Not checked for releases yet.")
    Req.Test.allow(Crew.GitHub, self(), view.pid)

    view |> element("#check-for-updates") |> render_click()
    assert render_async(view) =~ "Crew #{next_version()} is available"
  end

  test "a failed check says why", %{conn: conn} do
    GitHubStub.stub(%{{"GET", "/repos/ntodd/crew/releases"} => {503, %{}}})
    {:error, _} = Crew.Updates.check()

    {:ok, view, _html} = live(conn, "/admin")
    assert has_element?(view, "#crew-update", "The last check failed: GitHub answered 503")
  end

  test "CREW_UPDATE_CHECK=false: no checks, and says so", %{conn: conn} do
    Application.put_env(:crew, :update_check, false)

    {:ok, view, _html} = live(conn, "/admin")
    assert has_element?(view, "#update-check-off", "CREW_UPDATE_CHECK=false")
    refute has_element?(view, "#check-for-updates")
  end
end
