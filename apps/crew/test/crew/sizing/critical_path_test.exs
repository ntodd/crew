defmodule Crew.Sizing.CriticalPathTest do
  @moduledoc "A run attempt's critical path (§7.5), inferred from its jobs' times."
  use ExUnit.Case, async: true

  alias Crew.Sizing.CriticalPath

  @t0 ~U[2026-11-09 02:35:18Z]

  # A job queued, started and finished this many seconds after @t0.
  defp job(id, queued, started, completed) do
    %{
      id: id,
      queued_at: DateTime.add(@t0, queued),
      started_at: DateTime.add(@t0, started),
      completed_at: DateTime.add(@t0, completed)
    }
  end

  test "a job alone in its run is on its path" do
    assert CriticalPath.ids([job(:only, 0, 5, 600)]) == MapSet.new([:only])
  end

  test "the last job to finish, back through each job that finished as it was queued" do
    # check, then lint and build (test needs build), then deploy needs
    # lint and test. The chain is check, build, test, deploy.
    jobs = [
      job(:check, 0, 1, 15),
      job(:lint, 15, 17, 60),
      job(:build, 15, 17, 120),
      job(:test, 120, 122, 400),
      job(:deploy, 400, 402, 450)
    ]

    assert CriticalPath.ids(jobs) == MapSet.new([:check, :build, :test, :deploy])
  end

  test "a release run as GitHub reported it" do
    # Jobs and times from one of Crew's release runs. Its chain: check,
    # guest / check, guest / build (x64), sign, verify, images
    # (sqlite, amd64), manifest, publish; images (postgres, arm64)
    # finished 27 s before the images job manifest waited for.
    at = &DateTime.add(~U[2026-11-09 02:00:00Z], &1)

    jobs =
      for {id, q, s, c} <- [
            {:check, 2118, 2119, 2133},
            {:native_linux, 2133, 2135, 2176},
            {:native_darwin, 2133, 2136, 2240},
            {:guest_check, 2133, 2135, 2160},
            {:ci_browser, 2133, 2135, 2371},
            {:ci_native, 2133, 2136, 2271},
            {:guest_build_arm64, 2160, 2164, 2662},
            {:guest_build_x64, 2160, 2162, 2900},
            {:agents_linux, 2371, 2373, 2544},
            {:sign, 2900, 2903, 2953},
            {:verify, 2953, 2955, 3009},
            {:images_postgres, 3009, 3011, 3134},
            {:images_sqlite, 3009, 3011, 3161},
            {:manifest, 3161, 3163, 3174},
            {:publish, 3174, 3176, 3272}
          ],
          do: %{id: id, queued_at: at.(q), started_at: at.(s), completed_at: at.(c)}

    assert CriticalPath.ids(jobs) ==
             MapSet.new([
               :check,
               :guest_check,
               :guest_build_x64,
               :sign,
               :verify,
               :images_postgres,
               :images_sqlite,
               :manifest,
               :publish
             ])
  end

  test "a job queued at the run's start is where the path begins, however late it started" do
    # Both start together; :slow waited for a runner past the time :quick
    # finished, but GitHub queued it at the start, so :quick isn't on it.
    jobs = [job(:quick, 0, 1, 60), job(:slow, 0, 90, 600)]
    assert CriticalPath.ids(jobs) == MapSet.new([:slow])
  end

  test "a job finishing a second off its dependent's queue time still counts" do
    jobs = [job(:build, 0, 1, 120), job(:test, 121, 123, 400)]
    assert CriticalPath.ids(jobs) == MapSet.new([:build, :test])
  end

  test "never a job that finished after its dependent was queued" do
    # :build finished as :test was queued; :lint a second later can't be
    # what :test waited for.
    jobs = [job(:build, 0, 1, 119), job(:lint, 0, 1, 121), job(:test, 120, 122, 400)]
    assert CriticalPath.ids(jobs) == MapSet.new([:build, :test])
  end

  test "jobs that finish together are all on it, whatever their order" do
    # Matrix legs: speeding up one alone wouldn't finish the run sooner,
    # but the size they share would.
    legs = [job(:leg1, 0, 1, 590), job(:leg2, 0, 1, 600), job(:leg3, 0, 1, 598)]
    assert CriticalPath.ids(legs) == MapSet.new([:leg1, :leg2, :leg3])
    assert CriticalPath.ids(Enum.reverse(legs)) == MapSet.new([:leg1, :leg2, :leg3])

    # And builds a deploy waited for, 5% of the run apart.
    builds = [job(:a, 0, 1, 300), job(:b, 0, 1, 280), job(:c, 0, 1, 100)]

    assert CriticalPath.ids(builds ++ [job(:deploy, 300, 302, 400)]) ==
             MapSet.new([:a, :b, :deploy])
  end

  test "nothing to say when the walk stops short of the run's start" do
    # Queued long after anything finished: GitHub was slow to queue it, or
    # Crew missed what it waited for.
    jobs = [job(:build, 0, 1, 120), job(:deploy, 600, 602, 700)]
    assert CriticalPath.ids(jobs) == nil
  end

  test "falls back to the start time for a job without a queue time" do
    jobs = [job(:build, 0, 1, 120), %{job(:test, 0, 120, 400) | queued_at: nil}]
    assert CriticalPath.ids(jobs) == MapSet.new([:build, :test])
  end

  test "nothing to say about a run with a job still going, or no jobs" do
    running = %{job(:test, 120, 122, 400) | completed_at: nil}
    assert CriticalPath.ids([job(:build, 0, 1, 120), running]) == nil
    assert CriticalPath.ids([]) == nil
  end
end
