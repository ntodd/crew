defmodule Crew.Jobs.CacheMisses do
  @moduledoc """
  Dependency steps that look like they never hit their cache (§16.7), from
  a job's last successful runs.

  A **dependency step** installs or fetches what the job needs: `mix
  deps.get`, `npm ci` and the other installs, a `setup-*` action or a
  step whose name starts "Set up" (not the runner's "Set up job"; not
  Buildx or QEMU, which have nothing to cache), and the post step of a
  cache (`Post Run actions/cache@v4`), which saves only on a miss. A
  cache's restore isn't one: a miss is the restore's fast case.

  One **misses its cache** when, over the job's last #{10} runs, it ran in
  at least #{5}, and even its fastest run took #{15} s or more and at
  least half its p50. A cache that hit even once would have made one run
  much faster. A skipped step counts as a run of 0 s, since a step
  skipped on a cache hit is the usual pattern; a step that failed or was
  cancelled doesn't count.

  A step is known by its name and which step of that name it is in its
  run (the first, the second), so two installs with the same name stay
  apart.
  """

  alias Crew.Jobs.Insights

  @runs 10
  @min_runs 5
  @min_s 15

  @not_dependencies ["set up job", "complete job"]

  # Installs and fetches, by the command they run.
  @install ~r/
      deps\.get | deps\.compile
    | \b(npm|yarn|pnpm|bun|composer)\s+(ci|install)\b
    | \bbundle\s+install\b | \bpip3?\s+install\b | \bpoetry\s+install\b | \buv\s+sync\b
    | \bgo\s+mod\s+download\b | \bcargo\s+fetch\b
  /xi

  # Setup actions and steps, and steps named for dependencies.
  @named ~r/setup- | ^set\s?up\s | \bdependencies\b | \bdeps\b/xi

  @nothing_to_cache ~r/buildx|qemu/i

  @cache ~r/\bcache\b/i

  @type key :: {String.t(), pos_integer()}

  @type miss :: %{
          runs: pos_integer(),
          p50: non_neg_integer(),
          fastest: non_neg_integer(),
          number: integer() | nil,
          run: non_neg_integer()
        }

  @doc "How many of a job's newest runs `find/1` looks at."
  def runs, do: @runs

  @doc "Whether a step's name says it fetches or installs dependencies."
  @spec dependency?(String.t() | nil) :: boolean()
  def dependency?(name) when is_binary(name) do
    cond do
      String.downcase(name) in @not_dependencies -> false
      Regex.match?(@nothing_to_cache, name) -> false
      Regex.match?(@install, name) -> true
      Regex.match?(@cache, name) -> String.starts_with?(name, "Post ")
      true -> Regex.match?(@named, name)
    end
  end

  def dependency?(_name), do: false

  @doc """
  Each of `steps` (in order) with its key: its name, and which step of
  that name it is, from 1. Takes GitHub's steps or the page's.
  """
  @spec keyed([map()] | nil) :: [{key(), map()}]
  def keyed(steps) do
    steps
    |> List.wrap()
    |> Enum.map_reduce(%{}, fn s, seen ->
      name = name(s)
      nth = Map.get(seen, name, 0) + 1
      {{{name, nth}, s}, Map.put(seen, name, nth)}
    end)
    |> elem(0)
  end

  @doc """
  The dependency steps that miss their cache, by key (`keyed/1`), given
  a job's successful runs' steps (as GitHub stores them), newest first.
  `run` is the index of the newest run with a run of the step that
  counts, and `number` the step's number there.
  """
  @spec find([[map()] | nil]) :: %{key() => miss()}
  def find(runs) do
    runs
    |> Enum.take(@runs)
    |> Enum.with_index()
    |> Enum.flat_map(fn {steps, i} ->
      for {{name, _} = key, s} <- keyed(steps),
          dependency?(name),
          d = seconds(s),
          d != nil,
          do: {key, %{run: i, number: s["number"], seconds: d}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {key, samples} -> miss(key, samples) end)
    |> Map.new()
  end

  defp miss(key, samples) do
    durations = Enum.map(samples, & &1.seconds)
    p50 = Insights.percentile(durations, 0.5)
    fastest = Enum.min(durations)
    newest = Enum.min_by(samples, & &1.run)

    if length(samples) >= @min_runs and fastest >= @min_s and fastest * 2 >= p50 do
      [
        {key,
         %{
           runs: length(samples),
           p50: p50,
           fastest: fastest,
           number: newest.number,
           run: newest.run
         }}
      ]
    else
      []
    end
  end

  defp name(%{"name" => name}) when is_binary(name), do: name
  defp name(%{name: name}) when is_binary(name), do: name
  defp name(_step), do: nil

  # What a run of the step says about its cache: how long it took, 0 for
  # skipped, nil when it doesn't count.
  defp seconds(%{"conclusion" => "skipped"}), do: 0

  defp seconds(%{"conclusion" => "success", "started_at" => from, "completed_at" => to})
       when is_binary(from) and is_binary(to) do
    with {:ok, a, _} <- DateTime.from_iso8601(from),
         {:ok, b, _} <- DateTime.from_iso8601(to),
         d when d >= 0 <- DateTime.diff(b, a) do
      d
    else
      _ -> nil
    end
  end

  defp seconds(_step), do: nil
end
