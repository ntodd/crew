defmodule Crew.Sizing.RulesTest do
  @moduledoc "Right-sizing hints (§7.5): each rule, and the guarantees a hint makes."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Crew.Sizing.Rules
  alias Crew.Sizing.Rules.Hint

  @xs %{name: "xs", vcpus: 1, memory_mib: 2048, disk_gib: 20}
  @s %{name: "s", vcpus: 2, memory_mib: 4096, disk_gib: 40}
  @m %{name: "m", vcpus: 4, memory_mib: 8192, disk_gib: 60}
  @l %{name: "l", vcpus: 8, memory_mib: 16_384, disk_gib: 100}
  @xl %{name: "xl", vcpus: 16, memory_mib: 32_768, disk_gib: 150}
  @sizes [@xs, @s, @m, @l, @xl]

  # A successful 10-minute run on m that a newer guest summarized in full.
  defp run(attrs \\ []) do
    Map.merge(
      %{
        conclusion: "success",
        vcpus: 4,
        memory_mib: 8192,
        peak_mem_mib: 1000,
        peak_disk_mib: 3000,
        cpu_excess: [0.0, 0.0, 0.0],
        cpu_pressure_pct: 0.0,
        mem_pressure_pct: 0.0,
        mem_full_pressure_pct: 0.0,
        oom: false,
        coverage: 1.0,
        duration_s: 600
      },
      Map.new(attrs)
    )
  end

  defp runs(n, attrs \\ []), do: List.duplicate(run(attrs), n)

  describe "no hint" do
    test "without runs" do
      assert Rules.hint([], @sizes) == nil
    end

    test "from runs an older guest summarized: they can't show a smaller size is safe" do
      assert Rules.hint(runs(10, mem_pressure_pct: nil), @sizes) == nil
      assert Rules.hint(runs(10, cpu_excess: nil), @sizes) == nil
    end

    test "with fewer than 5 complete successful runs" do
      assert Rules.hint(runs(4), @sizes) == nil
      assert Rules.hint(runs(4) ++ runs(3, conclusion: "failure"), @sizes) == nil
      # Coverage under 80%, or not yet final (nil), doesn't count.
      assert Rules.hint(runs(4) ++ runs(3, coverage: 0.5), @sizes) == nil
      assert Rules.hint(runs(4) ++ runs(3, coverage: nil), @sizes) == nil
    end
  end

  describe "smaller" do
    test "to the size with the least memory that holds the peak and keeps the CPU" do
      assert %Hint{kind: :smaller, to: @xs, from: from, runs: 5, saved_mib: 6144} =
               Rules.hint(runs(5), @sizes)

      assert %{name: "m", vcpus: 4, memory_mib: 8192} = from
    end

    test "only among the sizes it's given (the repo's allowed ones)" do
      assert %Hint{kind: :smaller, to: @s} = Rules.hint(runs(5), [@s, @m, @l])
    end

    test "keeps the vCPUs the work needs" do
      # On 1 vCPU: 120 core-seconds waiting, 20% of 600 s; on 2: 5%.
      hint = Rules.hint(runs(5, cpu_excess: [120.0, 60.0, 0.0]), @sizes)
      assert %Hint{kind: :smaller, to: @s} = hint

      assert Enum.any?(
               hint.reasons,
               &(&1 =~ "On 2 vCPUs, it would run up to 5% slower, by estimate.")
             )
    end

    test "holds the peak plus 25%, at least 512 MiB more" do
      # 1700 + 512 > 2048: xs is out.
      assert %Hint{kind: :smaller, to: @s} = Rules.hint(runs(5, peak_mem_mib: 1700), @sizes)
      # 3200 * 1.25 = 4000 fits s; 3300 * 1.25 = 4125 doesn't.
      assert %Hint{kind: :smaller, to: @s} = Rules.hint(runs(5, peak_mem_mib: 3200), @sizes)
      assert %Hint{kind: :fits} = Rules.hint(runs(5, peak_mem_mib: 3300), @sizes)
    end

    test "uses the highest peak of any run, even an incomplete or failed one" do
      runs =
        runs(5) ++
          [run(peak_mem_mib: 3000, coverage: 0.3), run(peak_mem_mib: 1500, conclusion: "failure")]

      assert %Hint{kind: :smaller, to: @s} = Rules.hint(runs, @sizes)
    end

    test "holds the peak disk plus 25%, at least 2 GiB more" do
      # 30 GiB used: 37.5 GiB needed, more than xs's 20; s's 40 holds it.
      assert %Hint{kind: :smaller, to: @s} = Rules.hint(runs(5, peak_disk_mib: 30_720), @sizes)
      # 49 GiB needed: only m has the disk, so a custom size is the fit.
      assert %Hint{kind: :custom, to: %{vcpus: 1, memory_mib: 2048, disk_gib: 50}} =
               Rules.hint(runs(5, peak_disk_mib: 40_000), [@xs, @s, @m])
    end

    test "a failed run that would have been slower blocks fewer vCPUs" do
      slow = run(conclusion: "failure", cpu_excess: [600.0, 300.0, 0.0])
      assert %Hint{to: to} = Rules.hint([run() | runs(4)] ++ [slow], @sizes)
      assert to.vcpus == 4
    end

    test "any run's estimate can keep the vCPUs, complete or not" do
      # Half its samples are missing, but what's there already says 1 vCPU
      # would be far slower.
      partial = run(coverage: 0.5, cpu_excess: [900.0, 600.0, 300.0])
      assert %Hint{to: to} = Rules.hint(runs(5) ++ [partial], @sizes)
      assert to.vcpus == 4
    end

    test "a memory stall below the larger hint's bar keeps the memory" do
      runs = runs(5) ++ [run(mem_pressure_pct: 12.0)]
      assert %Hint{kind: :fits} = Rules.hint(runs, @sizes)
    end
  end

  describe "custom" do
    test "when the job needs the vCPUs but none of the memory the sizes pair them with" do
      runs = runs(5, cpu_excess: [1200.0, 600.0, 120.0], peak_mem_mib: 1000)

      assert %Hint{
               kind: :custom,
               to: %{vcpus: 4, memory_mib: 2048, disk_gib: 20},
               saved_mib: 6144
             } =
               hint = Rules.hint(runs, @sizes)

      assert hd(hint.reasons) ==
               "It needs 4 vCPUs and 2 GiB, but the closest allowed size, m, reserves 8 GiB."
    end

    test "not when an allowed size comes close" do
      runs = runs(5, cpu_excess: [1200.0, 600.0, 120.0], peak_mem_mib: 2600)
      # Needs 4 vCPUs and 3.25 GiB: a custom 4 GiB beats m's 8 GiB by 2x.
      assert %Hint{kind: :custom, to: %{memory_mib: 4096}} = Rules.hint(runs, @sizes)
      # 3.5 GiB needed rounds to 5 GiB: m's 8 isn't twice that.
      assert %Hint{kind: :fits} =
               Rules.hint(runs(5, cpu_excess: [1200.0, 600.0, 120.0], peak_mem_mib: 3300), @sizes)
    end

    test "has 1 or an even number of vCPUs, as sizes must" do
      # 3 vCPUs would do; sizes can't have 3.
      runs =
        runs(5,
          vcpus: 8,
          memory_mib: 16_384,
          cpu_excess: [900.0, 300.0, 20.0, 0.0, 0.0, 0.0, 0.0]
        )

      assert %Hint{kind: :custom, to: %{vcpus: 4}} = Rules.hint(runs, @sizes)
    end
  end

  describe "larger" do
    test "after a process was killed for memory, even once and with nothing else to go on" do
      assert %Hint{kind: :larger, to: @l, saved_mib: -8192, reasons: [reason]} =
               Rules.hint([run(oom: true, coverage: nil, conclusion: "failure")], @sizes)

      assert reason =~ "1 of the last 1 runs had a process killed for memory"
    end

    test "keeps at least the vCPUs it has" do
      sizes = [@m, %{name: "big-mem", vcpus: 2, memory_mib: 16_384, disk_gib: 60}, @l]
      assert %Hint{kind: :larger, to: @l} = Rules.hint([run(oom: true)], sizes)
    end

    test "adds vCPUs too when it's also waiting on a CPU" do
      starved = run(peak_mem_mib: 7400, cpu_pressure_pct: 40.0)
      assert %Hint{kind: :larger, to: @l} = Rules.hint([starved, starved, starved], [@m, @l])

      sizes = [@m, %{name: "m-plus", vcpus: 4, memory_mib: 12_288, disk_gib: 60}, @xl]
      assert %Hint{kind: :larger, to: @xl} = Rules.hint([starved, starved, starved], sizes)

      assert %Hint{kind: :larger, to: %{name: "m-plus"}} =
               Rules.hint([run(peak_mem_mib: 7400)], sizes)
    end

    test "never to a size without the disk the runs used" do
      thin = %{name: "thin", vcpus: 4, memory_mib: 12_288, disk_gib: 10}
      assert %Hint{to: @l} = Rules.hint([run(oom: true, peak_disk_mib: 20_000)], [@m, thin, @l])
    end

    test "never to fewer vCPUs than it has" do
      big_mem = %{name: "big-mem", vcpus: 2, memory_mib: 16_384, disk_gib: 60}
      assert %Hint{kind: :larger, to: nil} = Rules.hint([run(oom: true)], [@m, big_mem])
    end

    test "says so when no allowed size has more memory" do
      assert %Hint{kind: :larger, to: nil, reasons: [_, admin]} =
               Rules.hint([run(oom: true)], [@xs, @s, @m])

      assert admin =~ "No allowed size has more memory"
    end

    test "when most runs stalled on memory" do
      runs = [run(mem_pressure_pct: 15.0), run(mem_full_pressure_pct: 2.0), run()]
      assert %Hint{kind: :larger, to: @l} = Rules.hint(runs, @sizes)
      # One in three isn't most.
      assert Rules.hint([run(mem_pressure_pct: 15.0), run(), run()], @sizes) == nil
    end

    test "when a run peaked at 90% of its memory" do
      assert %Hint{kind: :larger, to: @l, reasons: [reason]} =
               Rules.hint([run(peak_mem_mib: 7400)], @sizes)

      assert reason =~ "Memory peaked at 90% of 8 GiB"
    end
  end

  describe "faster" do
    test "when most runs waited on a CPU a quarter of the time" do
      runs = runs(3, cpu_pressure_pct: 40.0, cpu_excess: [1800.0, 1200.0, 600.0]) ++ runs(2)
      assert %Hint{kind: :faster, to: @l, reasons: [reason]} = Rules.hint(runs, @sizes)
      assert reason =~ "tasks waited for a CPU 40% of the time or more"
    end

    test "keeps the memory of a job that stalled on it" do
      starved = run(cpu_pressure_pct: 40.0, cpu_excess: [1800.0, 1200.0, 600.0])
      stalled = %{starved | mem_pressure_pct: 12.0}
      lean = %{name: "lean", vcpus: 8, memory_mib: 2048, disk_gib: 60}

      assert %Hint{kind: :faster, to: @l} =
               Rules.hint(List.duplicate(starved, 4) ++ [stalled], [@m, lean, @l])
    end

    test "not from two starved runs, or with no size that has more vCPUs" do
      assert %Hint{kind: kind} = Rules.hint(runs(2, cpu_pressure_pct: 40.0) ++ runs(3), @sizes)
      refute kind == :faster
      runs = runs(5, cpu_pressure_pct: 40.0, cpu_excess: [1800.0, 1200.0, 600.0])
      assert %Hint{kind: kind} = Rules.hint(runs, [@s, @m])
      refute kind == :faster
    end
  end

  describe "the critical path" do
    @starved [cpu_pressure_pct: 40.0, cpu_excess: [1800.0, 1200.0, 600.0]]

    test "more vCPUs for a starved job on its run's critical path, saying so" do
      runs = runs(4, [critical: true] ++ @starved) ++ runs(1, [critical: false] ++ @starved)

      assert %Hint{kind: :faster, to: @l, reasons: [_, path]} = Rules.hint(runs, @sizes)
      assert path =~ "on its run's critical path in 4 of the 5 runs where it waited"
    end

    test "none for one off it: they'd take capacity without finishing the run sooner" do
      runs = runs(4, [critical: false] ++ @starved) ++ runs(1, [critical: true] ++ @starved)

      assert %Hint{kind: kind, reasons: reasons} = Rules.hint(runs, @sizes)
      refute kind == :faster

      assert Enum.any?(
               reasons,
               &(&1 =~ "off its run's critical path in 4 of the 5 runs where it waited")
             )
    end

    test "counts the starved runs whose path is known, and as before when none is" do
      runs =
        runs(3, [critical: true] ++ @starved) ++ runs(2, @starved) ++ runs(5, critical: false)

      assert %Hint{kind: :faster, reasons: [_, path]} = Rules.hint(runs, @sizes)
      assert path =~ "in 3 of the 3 runs where it waited that Crew could trace"

      assert %Hint{kind: :faster, reasons: [_]} = Rules.hint(runs(5, @starved), @sizes)
    end

    test "fewer than 3 traced starved runs don't decide it" do
      runs = runs(2, [critical: false] ++ @starved) ++ runs(3, @starved)
      assert %Hint{kind: :faster, reasons: [_]} = Rules.hint(runs, @sizes)
    end

    test "a larger size adds vCPUs only on the path" do
      sizes = [@m, %{name: "m-plus", vcpus: 4, memory_mib: 12_288, disk_gib: 60}, @xl]
      on = run([peak_mem_mib: 7400, critical: true] ++ @starved)
      off = %{on | critical: false}

      assert %Hint{kind: :larger, to: @xl} = Rules.hint([on, on, on], sizes)

      assert %Hint{kind: :larger, to: %{name: "m-plus"}, reasons: [_, why]} =
               Rules.hint([off, off, off], sizes)

      assert why =~ "off its run's critical path"
    end

    test "says nothing of the path for a job that isn't starved" do
      assert %Hint{reasons: reasons} = Rules.hint(runs(5, critical: false), @sizes)
      refute Enum.any?(reasons, &(&1 =~ "critical path"))
    end
  end

  describe "the runs that count" do
    test "only those on the shape the newest run used" do
      # It moved from l to m: l's runs, peaks and all, don't count.
      old =
        runs(5,
          vcpus: 8,
          memory_mib: 16_384,
          peak_mem_mib: 14_000,
          cpu_excess: List.duplicate(0.0, 7)
        )

      assert Rules.hint(runs(5) ++ old, @sizes) == Rules.hint(runs(5), @sizes)
      assert Rules.hint(runs(2) ++ old, @sizes) == nil
    end

    test "the shape is the newest run's, summarized or not" do
      # It moved to l; that run's guest was older, and the m runs don't
      # say anything about l.
      newest = run(vcpus: 8, memory_mib: 16_384, mem_pressure_pct: nil, peak_mem_mib: 12_000)
      assert Rules.hint([newest | runs(5)], @sizes) == nil

      # A newest run with no shape at all: nothing to say.
      assert Rules.hint([run(vcpus: nil, memory_mib: nil) | runs(5)], @sizes) == nil
    end

    test "the 10 newest" do
      newer = runs(10)
      assert Rules.hint(newer ++ [run(oom: true)], @sizes) == Rules.hint(newer, @sizes)
    end

    test "fits names the size, or none for a shape no size has" do
      assert %Hint{kind: :fits, from: %{name: "m"}} =
               Rules.hint(runs(5, peak_mem_mib: 5000), @sizes)

      odd =
        runs(5,
          vcpus: 6,
          memory_mib: 12_288,
          peak_mem_mib: 9000,
          cpu_excess: [2000.0, 1500.0, 1000.0, 500.0, 100.0]
        )

      assert %Hint{from: %{name: nil, vcpus: 6}} = Rules.hint(odd, @sizes)
    end
  end

  describe "slowdown/2" do
    test "is the waiting work done on that many vCPUs, over the duration" do
      r = run(cpu_excess: [300.0, 60.0, 6.0], duration_s: 600)
      assert Rules.slowdown(r, 1) == 0.5
      assert Rules.slowdown(r, 2) == 0.05
      assert Rules.slowdown(r, 3) == 6 / 3 / 600
      assert Rules.slowdown(r, 4) == 0.0
      assert Rules.slowdown(r, 8) == 0.0
    end

    test "is unknown without a duration or a profile" do
      assert Rules.slowdown(run(duration_s: 0), 1) == nil
      assert Rules.slowdown(run(duration_s: nil), 1) == nil
      assert Rules.slowdown(run(cpu_excess: nil), 1) == nil
      assert Rules.slowdown(run(cpu_excess: []), 1) == nil
    end
  end

  test "the headroom" do
    assert Rules.memory_needed(1000) == 1512
    assert Rules.memory_needed(4000) == 5000
    assert Rules.disk_needed(1000) == 3048
    assert Rules.disk_needed(20_000) == 25_000
  end

  # -- properties ------------------------------------------------------------------

  defp shape_gen do
    member_of([
      {1, 2048},
      {2, 4096},
      {4, 8192},
      {8, 16_384},
      {16, 32_768},
      {4, 4096},
      {6, 12_288}
    ])
  end

  # Mostly runs that could argue for a smaller size, so the properties
  # see plenty of smaller and custom hints, with the odd OOM, stall and
  # near-full run among them.
  defp run_gen({vcpus, memory}) do
    gen all(
          peak <- frequency([{8, integer(100..div(memory, 2))}, {1, integer(100..memory)}]),
          disk <- frequency([{8, integer(0..20_000)}, {1, integer(0..200_000)}]),
          duration <- integer(1..7200),
          pcts <-
            list_of(frequency([{3, float(min: 0.0, max: 0.05)}, {1, float(min: 0.0, max: 1.0)}]),
              length: max(vcpus - 1, 0)
            ),
          coverage <-
            frequency([{8, constant(1.0)}, {1, float(min: 0.0, max: 1.0)}, {1, constant(nil)}]),
          conclusion <- frequency([{8, constant("success")}, {1, constant("failure")}]),
          oom <- frequency([{40, constant(false)}, {1, constant(true)}]),
          mem_p <- frequency([{12, constant(0.0)}, {1, float(min: 0.0, max: 40.0)}]),
          cpu_p <- frequency([{8, constant(0.0)}, {1, float(min: 0.0, max: 90.0)}])
        ) do
      # Demand above v shrinks as v grows, as cpu_excess's always does.
      excess =
        pcts
        |> Enum.sort(:desc)
        |> Enum.with_index(1)
        |> Enum.map(fn {p, v} -> Float.round(p * duration * (vcpus - v), 1) end)

      run(
        vcpus: vcpus,
        memory_mib: memory,
        peak_mem_mib: peak,
        peak_disk_mib: disk,
        duration_s: duration,
        cpu_excess: excess,
        coverage: coverage,
        conclusion: conclusion,
        oom: oom,
        mem_pressure_pct: mem_p,
        cpu_pressure_pct: cpu_p
      )
    end
  end

  defp runs_gen do
    gen all(shape <- shape_gen(), runs <- list_of(run_gen(shape), min_length: 1, max_length: 12)) do
      runs
    end
  end

  defp sizes_gen do
    gen all(sizes <- list_of(member_of(@sizes), min_length: 1, max_length: 5)) do
      Enum.uniq(sizes)
    end
  end

  defp counted(runs) do
    [latest | _] = runs

    runs
    |> Enum.filter(&(&1.vcpus == latest.vcpus and &1.memory_mib == latest.memory_mib))
    |> Enum.take(10)
  end

  property "a smaller or custom size holds every run's peak memory and disk, and keeps it fast" do
    check all(runs <- runs_gen(), sizes <- sizes_gen(), max_runs: 500) do
      with %Hint{kind: kind, to: to} when kind in [:smaller, :custom] <- Rules.hint(runs, sizes) do
        counted = counted(runs)

        assert to.memory_mib >=
                 counted |> Enum.map(& &1.peak_mem_mib) |> Enum.max() |> Rules.memory_needed()

        assert to.disk_gib * 1024 >=
                 counted |> Enum.map(& &1.peak_disk_mib) |> Enum.max() |> Rules.disk_needed()

        for r <- counted, estimate = Rules.slowdown(r, to.vcpus), do: assert(estimate <= 0.05)

        refute Enum.any?(counted, & &1.oom)
        assert Enum.count(counted, &(Rules.complete?(&1) and &1.conclusion == "success")) >= 5
      end
    end
  end

  test "the generators produce every kind of hint, so the properties mean something" do
    kinds =
      runs_gen()
      |> StreamData.bind(fn runs -> StreamData.map(sizes_gen(), &{runs, &1}) end)
      |> StreamData.seeded(20_261_108)
      |> Enum.take(3000)
      |> Enum.map(fn {runs, sizes} -> Rules.hint(runs, sizes) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies_by(& &1.kind)

    for kind <- [:smaller, :custom, :larger, :fits],
        do: assert(kinds[kind] >= 20, "#{kind}: #{inspect(kinds)}")
  end

  property "a run killed for memory is always a larger hint" do
    check all(runs <- runs_gen(), sizes <- sizes_gen(), max_runs: 300) do
      if Enum.any?(counted(runs), & &1.oom) do
        assert %Hint{kind: :larger, to: to, from: from} = Rules.hint(runs, sizes)
        assert to == nil or to.memory_mib > from.memory_mib
      end
    end
  end

  property "a larger size keeps the vCPUs and holds the disk" do
    check all(runs <- runs_gen(), sizes <- sizes_gen(), max_runs: 300) do
      with %Hint{kind: :larger, to: %{} = to, from: from} <- Rules.hint(runs, sizes) do
        counted = counted(runs)
        assert to.vcpus >= from.vcpus

        assert to.disk_gib * 1024 >=
                 counted |> Enum.map(& &1.peak_disk_mib) |> Enum.max() |> Rules.disk_needed()
      end
    end
  end

  property "a named size is always one it was given" do
    check all(runs <- runs_gen(), sizes <- sizes_gen(), max_runs: 300) do
      case Rules.hint(runs, sizes) do
        %Hint{kind: kind, to: %{} = to} when kind in [:smaller, :larger, :faster] ->
          assert to in sizes

        _ ->
          :ok
      end
    end
  end

  # Where the hint would put the job: the size it names, or where it is.
  defp memory_after(%Hint{to: %{memory_mib: m}}), do: m
  defp memory_after(%Hint{from: from}), do: from.memory_mib

  property "more memory used never means a hint with less memory" do
    check all(
            runs <- runs_gen(),
            sizes <- sizes_gen(),
            more <- integer(0..4096),
            max_runs: 400
          ) do
      bigger = Enum.map(runs, &%{&1 | peak_mem_mib: min(&1.peak_mem_mib + more, &1.memory_mib)})

      with %Hint{} = before <- Rules.hint(runs, sizes),
           %Hint{} = after_ <- Rules.hint(bigger, sizes) do
        assert memory_after(after_) >= memory_after(before)
      end
    end
  end

  property "the order of the older runs doesn't matter" do
    check all(runs <- runs_gen(), sizes <- sizes_gen(), seed <- integer(), max_runs: 300) do
      [latest | older] = Enum.take(counted(runs), 10)
      :rand.seed(:exsss, {seed, seed, seed})

      assert Rules.hint([latest | Enum.shuffle(older)], sizes) ==
               Rules.hint([latest | older], sizes)
    end
  end
end
