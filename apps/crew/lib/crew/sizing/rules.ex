defmodule Crew.Sizing.Rules do
  @moduledoc """
  Right-sizing hints (§7.5): what the last runs of one job say about the
  size it runs on. Pure, so every rule is tested on its own; `Crew.Sizing`
  reads the runs and sizes.

  A run is a job's summary (§16.5) with its duration. Only runs on the
  shape the newest one ran on count, and only those a newer guest
  summarized: without the OOM count and the high-water mark, a run can't
  show that a smaller size is safe. Any of them can say a job needs more;
  only complete ones (a final summary whose samples cover 80% of the run)
  can say it needs less.

  Memory and CPU are sized separately. Memory is what limits placement
  (it's never overcommitted, §8.3), so the hint is always the size that
  reserves the least memory and still fits:

    * **larger** when a run had a process killed for memory, when most
      stalled on memory, or when one peaked at 90% of the VM's memory;
    * **faster** when most runs had tasks waiting for a CPU a quarter of
      the time or more, and a size with more vCPUs fits;
    * **smaller** to the allowed size with the least memory that holds the
      highest peak plus 25% (at least 512 MiB), the highest disk use plus
      25% (at least 2 GiB), and enough vCPUs to keep every run's estimated
      slowdown under 5%;
    * **custom** when no allowed size comes close: the best one reserves
      twice the memory of the shape the job needs, and 4 GiB more;
    * **fits** otherwise.

  The estimated slowdown on v vCPUs is the work that would have waited,
  `cpu_excess[v]` core-seconds, done on v vCPUs, over the run's duration.
  Shrinking needs 5 complete successful runs; growing needs one run.
  """

  defmodule Hint do
    @moduledoc """
    A hint: its `kind`, the shape the job runs on (`from`), the size to
    move to (`to`; a map of vCPUs, memory and disk for a custom one, nil
    when no allowed size is larger), the `runs` it's based on, why
    (`reasons`), and the memory a run would free (`saved_mib`, negative
    for a larger size).
    """
    @enforce_keys [:kind, :from, :runs]
    defstruct [:kind, :from, :to, :runs, reasons: [], saved_mib: 0]

    @type kind :: :larger | :faster | :smaller | :custom | :fits
    @type t :: %__MODULE__{}
  end

  @window 10
  @min_successes 5
  @min_coverage 0.8
  @headroom 0.25
  @min_headroom_mib 512
  @disk_headroom 0.25
  @min_disk_headroom_mib 2048
  @max_slowdown 0.05
  @tight 0.9
  @mem_stall_pct 10.0
  @mem_full_stall_pct 1.0
  @cpu_starved_pct 25.0
  @min_starved 3
  @custom_factor 2
  @custom_min_saving_mib 4096

  @doc "How many of a job's latest runs a hint looks at."
  def window, do: @window

  @doc """
  The hint for `runs` (newest first) among `sizes` (what the repo may
  use: maps with `name`, `vcpus`, `memory_mib` and `disk_gib`). Nil
  without a run to go on, or without enough to shrink and no reason to
  grow.
  """
  @spec hint([map()], [map()]) :: Hint.t() | nil
  def hint(runs, sizes) do
    with [%{vcpus: vcpus, memory_mib: memory} | _] when is_integer(vcpus) and is_integer(memory) <-
           runs,
         shape = %{vcpus: vcpus, memory_mib: memory, name: name_of(vcpus, memory, sizes)},
         [_ | _] = counted <- counted(runs, shape) do
      decide(counted, shape, sizes)
    else
      _ -> nil
    end
  end

  # The newest runs on the shape the newest one ran on, those a newer
  # guest summarized.
  defp counted(runs, shape) do
    runs
    |> Enum.filter(&same_shape?(&1, shape))
    |> Enum.take(@window)
    |> Enum.filter(&summarized?/1)
  end

  @doc "The memory a run needs, with headroom: its peak plus 25%, at least 512 MiB more."
  def memory_needed(peak_mib), do: peak_mib + max(ceil(peak_mib * @headroom), @min_headroom_mib)

  @doc "The disk a run needs, in MiB: its peak plus 25%, at least 2 GiB more."
  def disk_needed(peak_mib),
    do: peak_mib + max(ceil(peak_mib * @disk_headroom), @min_disk_headroom_mib)

  @doc """
  A run's estimated slowdown on `v` vCPUs, as a share of its duration:
  the work that would have waited on `v`, done on `v`. 0 on its own
  vCPUs or more; nil without what it takes to say.
  """
  def slowdown(%{vcpus: vcpus}, v) when v >= vcpus, do: 0.0

  def slowdown(%{cpu_excess: excess, duration_s: d}, v)
      when is_list(excess) and is_number(d) and d > 0 and v >= 1 do
    case Enum.at(excess, v - 1) do
      e when is_number(e) -> e / v / d
      _ -> nil
    end
  end

  def slowdown(_run, _v), do: nil

  defp summarized?(run) do
    is_integer(run[:vcpus]) and is_integer(run[:memory_mib]) and is_integer(run[:peak_mem_mib]) and
      is_list(run[:cpu_excess]) and is_number(run[:mem_pressure_pct])
  end

  @doc "Whether a run's final summary covers enough of it to argue for less."
  def complete?(run), do: is_number(run[:coverage]) and run.coverage >= @min_coverage

  defp same_shape?(run, shape),
    do: run[:vcpus] == shape.vcpus and run[:memory_mib] == shape.memory_mib

  defp name_of(vcpus, memory, sizes) do
    Enum.find_value(sizes, fn s -> s.vcpus == vcpus and s.memory_mib == memory and s.name end)
  end

  defp decide(runs, shape, sizes) do
    n = length(runs)
    ooms = Enum.count(runs, & &1.oom)
    stalled = Enum.count(runs, &memory_stalled?/1)
    peak = runs |> Enum.map(& &1.peak_mem_mib) |> Enum.max()
    successes = Enum.count(runs, &(complete?(&1) and &1.conclusion == "success"))

    cond do
      ooms > 0 ->
        larger(runs, shape, sizes, [
          "#{ooms} of the last #{n} runs had a process killed for memory."
        ])

      stalled >= 2 and stalled * 2 >= n ->
        larger(runs, shape, sizes, [
          "#{stalled} of the last #{n} runs stalled on memory for #{pct(max_mem_stall(runs))} of the time or more."
        ])

      peak >= @tight * shape.memory_mib ->
        larger(runs, shape, sizes, [
          "Memory peaked at #{pct(peak / shape.memory_mib * 100)} of #{gib(shape.memory_mib)} GiB."
        ])

      successes < @min_successes ->
        nil

      true ->
        faster(runs, shape, sizes) || fit(runs, shape, sizes)
    end
  end

  defp memory_stalled?(run) do
    (run.mem_pressure_pct || 0) >= @mem_stall_pct or
      (run[:mem_full_pressure_pct] || 0) >= @mem_full_stall_pct
  end

  defp max_mem_stall(runs) do
    runs |> Enum.filter(&memory_stalled?/1) |> Enum.map(& &1.mem_pressure_pct) |> Enum.min()
  end

  # More memory and the disk the runs used, keeping the vCPUs it has, or
  # adding some when it's also waiting on a CPU: what it would get from
  # the faster hint. Never fewer vCPUs.
  defp larger(runs, shape, sizes, reasons) do
    disk = disk_floor(runs)

    bigger =
      Enum.filter(
        sizes,
        &(&1.memory_mib > shape.memory_mib and &1.disk_gib * 1024 >= disk and
            &1.vcpus >= shape.vcpus)
      )

    least = if cpu_starved?(runs), do: shape.vcpus + 1, else: shape.vcpus

    to =
      Enum.find_value([least, shape.vcpus], fn v ->
        bigger |> Enum.filter(&(&1.vcpus >= v)) |> smallest()
      end)

    reasons =
      if to,
        do: reasons,
        else:
          reasons ++
            ["No allowed size has more memory with its vCPUs and disk; an admin can add one."]

    %Hint{
      kind: :larger,
      from: shape,
      to: to,
      runs: length(runs),
      reasons: reasons,
      saved_mib: if(to, do: shape.memory_mib - to.memory_mib, else: 0)
    }
  end

  defp starved_runs(runs),
    do: Enum.filter(runs, &((&1[:cpu_pressure_pct] || 0) >= @cpu_starved_pct))

  defp cpu_starved?(runs) do
    starved = length(starved_runs(runs))
    starved >= @min_starved and starved * 2 >= length(runs)
  end

  defp faster(runs, shape, sizes) do
    starved = starved_runs(runs)
    n = length(runs)

    with true <- cpu_starved?(runs),
         %{} = to <-
           sizes
           |> Enum.filter(&(&1.vcpus > shape.vcpus and fits_memory_and_disk?(&1, runs, shape)))
           |> Enum.min_by(&{&1.vcpus, &1.memory_mib, &1.disk_gib}, fn -> nil end) do
      least = starved |> Enum.map(& &1.cpu_pressure_pct) |> Enum.min()

      %Hint{
        kind: :faster,
        from: shape,
        to: to,
        runs: n,
        reasons: [
          "In #{length(starved)} of the last #{n} runs, tasks waited for a CPU #{pct(least)} of the time or more."
        ],
        saved_mib: shape.memory_mib - to.memory_mib
      }
    else
      _ -> nil
    end
  end

  defp fits_memory_and_disk?(size, runs, shape) do
    size.memory_mib >= memory_needed_for(runs, shape) and
      size.disk_gib * 1024 >= disk_floor(runs)
  end

  # The memory a new size must have: the highest peak with headroom, and
  # never less than now if a run stalled on memory at all.
  defp memory_needed_for(runs, shape) do
    floor = if Enum.any?(runs, &memory_stalled?/1), do: shape.memory_mib, else: 0
    max(memory_floor(runs), floor)
  end

  # The memory a smaller size must have: the highest peak with headroom.
  defp memory_floor(runs),
    do: runs |> Enum.map(& &1.peak_mem_mib) |> Enum.max() |> memory_needed()

  defp disk_floor(runs),
    do: runs |> Enum.map(&(&1[:peak_disk_mib] || 0)) |> Enum.max() |> disk_needed()

  defp fit(runs, shape, sizes) do
    memory = memory_needed_for(runs, shape)
    disk = disk_floor(runs)
    vcpus_ok? = &enough_vcpus?(runs, shape, &1)

    best =
      sizes
      |> Enum.filter(
        &(&1.memory_mib >= memory and &1.disk_gib * 1024 >= disk and vcpus_ok?.(&1.vcpus))
      )
      |> smallest()

    custom = custom_shape(shape, memory, disk, vcpus_ok?)
    reference = best || shape

    cond do
      worth_custom?(reference, custom) ->
        hint(:custom, runs, shape, custom, custom_reasons(runs, custom, reference))

      best && smaller?(best, shape) ->
        hint(:smaller, runs, shape, best, smaller_reasons(runs, shape, best))

      true ->
        %Hint{
          kind: :fits,
          from: shape,
          to: nil,
          runs: length(runs),
          reasons: fits_reasons(runs, shape)
        }
    end
  end

  defp hint(kind, runs, shape, to, reasons) do
    %Hint{
      kind: kind,
      from: shape,
      to: to,
      runs: length(runs),
      reasons: reasons,
      saved_mib: shape.memory_mib - to.memory_mib
    }
  end

  # Fewer vCPUs than the runs had: enough complete successful runs with an
  # estimate to go on, and no run's estimate over the bar. An incomplete
  # run's estimate counts against it too: the work its samples saw was
  # done, whatever they missed. As many or more vCPUs are always enough.
  defp enough_vcpus?(_runs, shape, v) when v >= shape.vcpus, do: true

  defp enough_vcpus?(runs, _shape, v) do
    sound =
      Enum.count(
        runs,
        &(complete?(&1) and &1.conclusion == "success" and is_number(slowdown(&1, v)))
      )

    sound >= @min_successes and Enum.all?(runs, &within_bar?(&1, v))
  end

  defp within_bar?(run, v) do
    case slowdown(run, v) do
      nil -> not complete?(run)
      e -> e <= @max_slowdown
    end
  end

  defp worst_slowdown(runs, v) do
    runs
    |> Enum.map(&slowdown(&1, v))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0.0 end)
  end

  # The shape the job needs: the fewest vCPUs that keep it under the bar
  # (1 or an even count, as sizes allow), and its memory and disk rounded
  # up to whole GiB and to 10 GiB.
  defp custom_shape(shape, memory, disk, vcpus_ok?) do
    vcpus = Enum.find([1 | Enum.to_list(2..max(shape.vcpus, 2)//2)], shape.vcpus, vcpus_ok?)

    %{
      name: nil,
      vcpus: vcpus,
      memory_mib: max(ceil(memory / 1024), 1) * 1024,
      disk_gib: max(ceil(disk / 1024 / 10) * 10, 20)
    }
  end

  defp worth_custom?(reference, custom) do
    reference.memory_mib >= @custom_factor * custom.memory_mib and
      reference.memory_mib - custom.memory_mib >= @custom_min_saving_mib
  end

  defp smaller?(best, shape) do
    best.memory_mib < shape.memory_mib or
      (best.memory_mib == shape.memory_mib and best.vcpus < shape.vcpus)
  end

  defp smallest(sizes),
    do: Enum.min_by(sizes, &{&1.memory_mib, &1.vcpus, &1.disk_gib}, fn -> nil end)

  defp peak_line(runs) do
    peak = runs |> Enum.map(& &1.peak_mem_mib) |> Enum.max()
    "Memory peaked at #{gib(peak)} GiB over the last #{length(runs)} runs."
  end

  defp cpu_line(runs, shape, v) when v < shape.vcpus do
    worst = worst_slowdown(runs, v) * 100
    by = if worst < 1, do: "under 1%", else: "up to #{round(worst)}%"
    ["On #{v} vCPU#{if v > 1, do: "s"}, it would run #{by} slower, by estimate."]
  end

  defp cpu_line(_runs, _shape, _v), do: []

  defp smaller_reasons(runs, shape, best),
    do: [peak_line(runs) | cpu_line(runs, shape, best.vcpus)]

  defp custom_reasons(runs, custom, reference) do
    [
      "It needs #{custom.vcpus} vCPU#{if custom.vcpus > 1, do: "s"} and #{gib(custom.memory_mib)} GiB, " <>
        "but the closest allowed size, #{reference_name(reference)}, reserves #{gib(reference.memory_mib)} GiB.",
      peak_line(runs)
    ] ++ cpu_line(runs, %{vcpus: reference.vcpus}, custom.vcpus)
  end

  defp reference_name(%{name: name}) when is_binary(name), do: name
  defp reference_name(_shape), do: "its own"

  defp fits_reasons(runs, shape) do
    [
      peak_line(runs) <>
        " Its #{gib(shape.memory_mib)} GiB leaves headroom without much to spare."
    ]
  end

  defp gib(mib) do
    g = Float.round(mib / 1024, 1)
    if g == Float.round(g), do: trunc(g), else: g
  end

  defp pct(x) when x < 1, do: "under 1%"
  defp pct(x), do: "#{round(x)}%"
end
