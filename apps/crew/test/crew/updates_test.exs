defmodule Crew.UpdatesTest do
  @moduledoc """
  New Crew releases and updating to them from the UI (§20.3): the daily
  check against CREW_UPDATE_REPO's releases, and the request the host's
  crew-update takes.
  """
  use Crew.DataCase, async: false
  use Oban.Testing, repo: Crew.Repo

  import Crew.Fixtures

  alias Crew.{GitHubStub, Scope, Updates}

  @moduletag :tmp_dir

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

  defp release(tag, opts \\ []) do
    %{
      "tag_name" => tag,
      "html_url" => "https://github.com/ntodd/crew/releases/tag/#{tag}",
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false)
    }
  end

  defp stub_releases(releases, repo \\ "ntodd/crew"),
    do: GitHubStub.stub(%{{"GET", "/repos/#{repo}/releases"} => {200, releases}})

  # A release newer than this control plane (whatever CREW_VERSION built it).
  defp next_version do
    v = Version.parse!(Crew.Config.version())
    "#{v.major}.#{v.minor + 1}.0"
  end

  defp install_updater(dir), do: File.write!(Path.join([dir, "status", "updater"]), "1\n")

  describe "check/0" do
    test "keeps the highest published vX.Y.Z, passing over drafts, prereleases and odd tags" do
      stub_releases([
        release("v9.0.0", draft: true),
        release("v8.0.0-rc.1"),
        release("v7.0.0", prerelease: true),
        release("v0.2.10"),
        release("v0.2.9"),
        release("v01.0.0"),
        release("v10000.0.0"),
        release("nightly"),
        release("v1.0")
      ])

      assert {:ok, %{version: "0.2.10"}} = Updates.check()

      latest = Updates.latest()
      assert latest.version == "0.2.10"
      assert latest.url == "https://github.com/ntodd/crew/releases/tag/v0.2.10"
      assert %DateTime{} = latest.checked_at
      assert latest.error == nil
    end

    test "asks CREW_UPDATE_REPO" do
      Application.put_env(:crew, :update_repo, "acme/crew-fork")
      stub_releases([release("v3.1.4")], "acme/crew-fork")

      assert {:ok, %{version: "3.1.4"}} = Updates.check()
    end

    test "a failed check keeps the last release it found, and says why" do
      stub_releases([release("v0.5.0")])
      {:ok, _} = Updates.check()

      GitHubStub.stub(%{{"GET", "/repos/ntodd/crew/releases"} => {502, %{}}})
      assert {:error, _} = Updates.check()

      latest = Updates.latest()
      assert latest.version == "0.5.0"
      assert latest.error == "GitHub answered 502"
    end

    test "a repo with no releases has no latest" do
      stub_releases([])
      assert {:ok, nil} = Updates.check()
      assert %{version: nil, error: nil} = Updates.latest()
      assert Updates.available() == nil
    end
  end

  test "available/0: the latest release, only when it's newer than this one" do
    assert Updates.available() == nil

    stub_releases([release("v" <> next_version())])
    {:ok, _} = Updates.check()
    assert %{version: version} = Updates.available()
    assert version == next_version()

    stub_releases([release("v" <> Crew.Config.version())])
    {:ok, _} = Updates.check()
    assert Updates.available() == nil
  end

  describe "the daily check" do
    test "runs from cron once a day" do
      crontab =
        Application.fetch_env!(:crew, Oban)[:plugins]
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> opts[:crontab]
          _ -> nil
        end)

      assert [{schedule, Updates.Check}] = Enum.filter(crontab, &match?({_, Updates.Check}, &1))
      assert [_minute, hour, "*", "*", "*"] = String.split(schedule)
      assert Integer.parse(hour) != :error
    end

    test "asks GitHub" do
      stub_releases([release("v4.5.6")])
      assert :ok = perform_job(Updates.Check, %{})
      assert Updates.latest().version == "4.5.6"
    end

    test "CREW_UPDATE_CHECK=false turns it off" do
      Application.put_env(:crew, :update_check, false)
      GitHubStub.stub(%{})

      assert :ok = perform_job(Updates.Check, %{})
      assert Updates.latest() == nil
    end
  end

  describe "the host's updater" do
    test "isn't installed until it says so", %{dir: dir} do
      assert %{installed: false} = Updates.updater()
      install_updater(dir)
      assert %{installed: true, state: nil} = Updates.updater()
    end

    test "reads its last run", %{dir: dir} do
      install_updater(dir)
      at = DateTime.utc_now() |> DateTime.truncate(:second)

      File.write!(
        Path.join([dir, "status", "state.json"]),
        JSON.encode!(%{
          "state" => "rolled_back",
          "from" => "0.1.0",
          "to" => "0.2.0",
          "message" => "0.2.0 didn't come up healthy, so 0.1.0 is back.",
          "at" => DateTime.to_iso8601(at)
        })
      )

      assert %{state: "rolled_back", from: "0.1.0", to: "0.2.0", at: ^at} = Updates.updater()
    end

    test "a run that stopped reporting is stale", %{dir: dir} do
      install_updater(dir)
      at = DateTime.add(DateTime.utc_now(), -31 * 60)

      File.write!(
        Path.join([dir, "status", "state.json"]),
        JSON.encode!(%{"state" => "running", "at" => DateTime.to_iso8601(at)})
      )

      assert %{state: "stale"} = Updates.updater()
    end

    test "a request it hasn't taken yet is pending", %{dir: dir} do
      install_updater(dir)
      File.write!(Path.join([dir, "request", "version"]), "0.9.0\n")
      assert %{state: "pending", to: "0.9.0"} = Updates.updater()
    end
  end

  describe "request/2" do
    setup %{dir: dir} do
      install_updater(dir)
      stub_releases([release("v" <> next_version())])
      {:ok, _} = Updates.check()
      %{admin: Scope.for_user(user_fixture(role: "admin"))}
    end

    test "writes the version for the host's updater, and audits it", %{admin: admin, dir: dir} do
      version = next_version()
      assert :ok = Updates.request(admin, version)

      assert File.read!(Path.join([dir, "request", "version"])) == version <> "\n"
      assert %{state: "pending", to: ^version} = Updates.updater()

      assert [event] = Crew.Audit.recent() |> Enum.filter(&(&1.action == "crew.update"))
      assert event.actor_id == admin.user.id
      assert event.metadata == %{"from" => Crew.Config.version(), "to" => version}
    end

    test "only an admin can ask", %{dir: dir} do
      member = Scope.for_user(user_fixture())
      assert {:error, :forbidden} = Updates.request(member, next_version())
      refute File.exists?(Path.join([dir, "request", "version"]))
    end

    test "only for the release the last check found newer", %{admin: admin} do
      assert {:error, :not_available} = Updates.request(admin, "99.0.0")
      assert {:error, :not_available} = Updates.request(admin, Crew.Config.version())
    end

    test "not without the updater", %{admin: admin, dir: dir} do
      File.rm!(Path.join([dir, "status", "updater"]))
      assert {:error, :no_updater} = Updates.request(admin, next_version())
    end

    test "not while an update is under way", %{admin: admin, dir: dir} do
      assert :ok = Updates.request(admin, next_version())
      assert {:error, :in_progress} = Updates.request(admin, next_version())

      File.rm!(Path.join([dir, "request", "version"]))

      File.write!(
        Path.join([dir, "status", "state.json"]),
        JSON.encode!(%{"state" => "running", "at" => DateTime.to_iso8601(DateTime.utc_now())})
      )

      assert {:error, :in_progress} = Updates.request(admin, next_version())
    end
  end
end
