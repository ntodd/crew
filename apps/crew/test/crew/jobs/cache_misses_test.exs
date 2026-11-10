defmodule Crew.Jobs.CacheMissesTest do
  use ExUnit.Case, async: true

  alias Crew.Jobs.CacheMisses

  # One run's steps as GitHub stores them: `{name, seconds}`, or
  # `{name, seconds, conclusion}`, numbered in order.
  defp run(steps) do
    start = ~U[2026-11-03 10:00:00Z]

    steps
    |> Enum.with_index(1)
    |> Enum.map_reduce(start, fn {step, n}, at ->
      {name, s, conclusion} =
        case step do
          {name, s} -> {name, s, "success"}
          {name, s, conclusion} -> {name, s, conclusion}
        end

      done = DateTime.add(at, s)

      {%{
         "name" => name,
         "number" => n,
         "status" => "completed",
         "conclusion" => conclusion,
         "started_at" => DateTime.to_iso8601(at),
         "completed_at" => DateTime.to_iso8601(done)
       }, done}
    end)
    |> elem(0)
  end

  defp runs(durations, name \\ "Run mix deps.get"),
    do: for(s <- durations, do: run([{"Set up job", 2}, {name, s}, {"Run mix test", 90}]))

  describe "dependency?/1" do
    test "installs, fetches and setup actions are dependency steps" do
      for name <- [
            "Run mix deps.get",
            "Run npm ci",
            "Run npm install",
            "Run yarn install --frozen-lockfile",
            "Run pnpm install",
            "Run bundle install",
            "Run pip install -r requirements.txt",
            "Run go mod download",
            "Run erlef/setup-beam@v1",
            "Run actions/setup-node@v4",
            "Set up Elixir",
            "Install dependencies",
            "Post Run actions/cache@v4",
            "Post Cache deps",
            "Run npm ci --cache .npm"
          ],
          do: assert(CacheMisses.dependency?(name), name)
    end

    test "a cache restore isn't one: a miss is the fast case" do
      refute CacheMisses.dependency?("Run actions/cache@v4")
      refute CacheMisses.dependency?("Cache deps")
      refute CacheMisses.dependency?("Run actions/cache/restore@v4")
    end

    test "the runner's own steps and the job's work aren't" do
      for name <- ["Set up job", "Complete job", "Run mix test", "Run actions/checkout@v4", nil],
          do: refute(CacheMisses.dependency?(name), inspect(name))
    end

    test "setup steps with nothing to cache aren't, nor a script that's only named setup" do
      for name <- [
            "Run docker/setup-buildx-action@v3",
            "Run docker/setup-qemu-action@v3",
            "Set up QEMU",
            "Set up Docker Buildx",
            "Run ./setup.sh"
          ],
          do: refute(CacheMisses.dependency?(name), name)
    end
  end

  describe "find/1" do
    test "a dependency step about as long on every run is flagged, with its typical and fastest time" do
      assert %{{"Run mix deps.get", 1} => miss} = CacheMisses.find(runs([40, 42, 38, 45, 41, 39]))
      assert miss.runs == 6
      assert miss.p50 == 40
      assert miss.fastest == 38
      assert miss.number == 2
    end

    test "one fast run means the cache hit at least once" do
      assert CacheMisses.find(runs([40, 42, 3, 45, 41, 39])) == %{}
    end

    test "a skipped step counts as a hit: it's skipped when the cache restored it" do
      durations = runs([40, 42, 45, 41, 39])
      skipped = run([{"Set up job", 2}, {"Run mix deps.get", 0, "skipped"}, {"Run mix test", 90}])
      assert CacheMisses.find([skipped | durations]) == %{}
    end

    test "a failed step doesn't count either way" do
      failed = run([{"Set up job", 2}, {"Run mix deps.get", 1, "failure"}])

      assert %{{"Run mix deps.get", 1} => %{runs: 5}} =
               CacheMisses.find([failed | runs([40, 42, 45, 41, 39])])
    end

    test "too few runs, or too quick to matter, isn't flagged" do
      assert CacheMisses.find(runs([40, 42, 45, 41])) == %{}
      assert CacheMisses.find(runs([8, 9, 8, 9, 8, 9])) == %{}
    end

    test "steps that aren't dependency steps aren't flagged, however steady" do
      assert CacheMisses.find(runs([40, 40, 40, 40, 40], "Run mix compile")) == %{}
    end

    test "only the 10 newest runs count, the first given" do
      newest = runs(List.duplicate(40, 10))
      older = runs([2, 2, 2])
      assert %{{"Run mix deps.get", 1} => %{runs: 10}} = CacheMisses.find(newest ++ older)
      assert CacheMisses.find(runs([2]) ++ newest) == %{}
    end

    test "a step's number is the newest run's" do
      newest = run([{"Set up job", 2}, {"Checkout", 1}, {"Run mix deps.get", 40}])

      assert %{{"Run mix deps.get", 1} => %{number: 3}} =
               CacheMisses.find([newest | runs([40, 40, 40, 40])])
    end

    test "two steps with the same name are told apart by which one they are" do
      runs =
        for _ <- 1..5,
            do: run([{"Run npm ci", 40}, {"Run npm ci", 2}])

      assert Map.keys(CacheMisses.find(runs)) == [{"Run npm ci", 1}]
      assert CacheMisses.find(Enum.take(runs, 3)) == %{}
    end

    test "the run its number is from: the newest with a run of the step that counts" do
      failed = run([{"Checkout", 1}, {"Run mix deps.get", 1, "failure"}])

      assert %{{"Run mix deps.get", 1} => %{number: 2, run: 1}} =
               CacheMisses.find([failed | runs([40, 40, 40, 40, 40])])
    end

    test "steps without times, or runs without steps, are ignored" do
      untimed = [%{"name" => "Run mix deps.get", "number" => 2, "conclusion" => "success"}]

      assert %{{"Run mix deps.get", 1} => %{runs: 5}} =
               CacheMisses.find([untimed, nil | runs([40, 40, 40, 40, 40])])
    end
  end
end
