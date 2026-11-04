defmodule Crew.Images.RunnerTest do
  @moduledoc "Runner version freshness (§13.1): warn at 14 days behind, alert at 21."
  use Crew.DataCase, async: false
  use Oban.Testing, repo: Crew.Repo

  alias Crew.GitHubStub
  alias Crew.Images.Runner

  @now ~U[2026-11-03 12:00:00Z]

  defp days_ago(n), do: @now |> DateTime.add(-n * 86_400) |> DateTime.to_iso8601()

  test "the daily check keeps actions/runner's releases, skipping drafts and prereleases" do
    GitHubStub.stub(%{
      {"GET", "/repos/actions/runner/releases"} =>
        {200,
         [
           %{
             "tag_name" => "v2.341.0",
             "published_at" => days_ago(1),
             "draft" => false,
             "prerelease" => true
           },
           %{
             "tag_name" => "v2.340.0",
             "published_at" => days_ago(10),
             "draft" => false,
             "prerelease" => false
           },
           %{
             "tag_name" => "v2.339.0",
             "published_at" => days_ago(30),
             "draft" => true,
             "prerelease" => false
           },
           %{
             "tag_name" => "v2.338.2",
             "published_at" => days_ago(40),
             "draft" => false,
             "prerelease" => false
           }
         ]}
    })

    assert :ok = perform_job(Runner, %{})
    assert [%{"version" => "2.340.0"}, %{"version" => "2.338.2"}] = Runner.releases()
  end

  test "how far an image's runner is behind: from the first release after it" do
    releases = [
      %{"version" => "2.341.0", "published_at" => days_ago(3)},
      %{"version" => "2.340.0", "published_at" => days_ago(16)},
      %{"version" => "2.338.2", "published_at" => days_ago(40)}
    ]

    assert %{days: 16, level: :warn, latest: "2.341.0"} =
             Runner.freshness("2.338.2", releases, @now)

    assert %{days: 3, level: :ok} = Runner.freshness("2.340.0", releases, @now)
    assert %{days: 0, level: :ok} = Runner.freshness("2.341.0", releases, @now)

    old = [%{"version" => "2.339.0", "published_at" => days_ago(22)} | releases]
    assert %{level: :alert} = Runner.freshness("2.338.2", old, @now)
    assert Runner.freshness("2.338.2", [], @now) == nil
    assert Runner.freshness("dev", releases, @now) == nil
  end
end
