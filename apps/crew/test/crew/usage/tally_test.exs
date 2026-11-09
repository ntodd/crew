defmodule Crew.Usage.TallyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Crew.Usage.Tally

  # 2026-11-03 00:00:00 UTC
  @day 1_793_664_000
  @window {@day, @day + 86_400}

  defp at(s), do: DateTime.from_unix!(@day + s)

  defp vm(marks, attrs \\ []) do
    Map.merge(
      %{
        requested_at: nil,
        idle_at: nil,
        busy_at: nil,
        finished_at: nil,
        failed_at: nil,
        destroyed_at: nil,
        vcpus: 4,
        memory_mib: 8192,
        vmm_overhead_mib: 0
      },
      Map.new(marks, fn {k, s} -> {k, s && at(s)} end)
    )
    |> Map.merge(Map.new(attrs))
  end

  defp phases(vm, {from, until} \\ @window) do
    vm |> Tally.vm(from, until) |> Map.take([:boot_s, :idle_s, :busy_s, :teardown_s])
  end

  describe "a VM's phases" do
    test "every mark present" do
      v =
        vm(
          requested_at: 100,
          idle_at: 130,
          busy_at: 200,
          finished_at: 800,
          failed_at: 900,
          destroyed_at: 810
        )

      assert phases(v) == %{boot_s: 30, idle_s: 70, busy_s: 600, teardown_s: 10}
    end

    test "failed while booting is boot, then teardown" do
      v = vm(requested_at: 100, failed_at: 160, destroyed_at: 170)
      assert phases(v) == %{boot_s: 60, idle_s: 0, busy_s: 0, teardown_s: 10}
    end

    test "reaped while idle has no busy phase" do
      v = vm(requested_at: 100, idle_at: 120, finished_at: 400, destroyed_at: 405)
      assert phases(v) == %{boot_s: 20, idle_s: 280, busy_s: 0, teardown_s: 5}
    end

    test "failed while busy" do
      v = vm(requested_at: 0, idle_at: 10, busy_at: 20, failed_at: 50, destroyed_at: 52)
      assert phases(v) == %{boot_s: 10, idle_s: 10, busy_s: 30, teardown_s: 2}
    end

    test "finished without failing" do
      v = vm(requested_at: 0, idle_at: 10, busy_at: 20, finished_at: 80, destroyed_at: 81)
      assert phases(v) == %{boot_s: 10, idle_s: 10, busy_s: 60, teardown_s: 1}
    end

    test "still live at the end of the window runs to its end" do
      v = vm(requested_at: 86_000, idle_at: 86_100, busy_at: 86_200)
      assert phases(v) == %{boot_s: 100, idle_s: 100, busy_s: 200, teardown_s: 0}
      assert Tally.vm(v, @day, @day + 86_300).busy_s == 100
    end

    test "a VM spanning midnight splits across both days" do
      v =
        vm(
          requested_at: 86_000,
          idle_at: 86_300,
          busy_at: 86_500,
          finished_at: 87_000,
          destroyed_at: 87_010
        )

      next = {@day + 86_400, @day + 2 * 86_400}

      assert phases(v) == %{boot_s: 300, idle_s: 100, busy_s: 0, teardown_s: 0}
      assert phases(v, next) == %{boot_s: 0, idle_s: 100, busy_s: 500, teardown_s: 10}
    end

    test "a mark earlier than the one before it is ignored" do
      # busy_at before idle_at: idle runs on to the teardown.
      v = vm(requested_at: 100, idle_at: 200, busy_at: 150, finished_at: 300, destroyed_at: 310)
      assert phases(v) == %{boot_s: 100, idle_s: 100, busy_s: 0, teardown_s: 10}
    end

    test "marks outside the held span are ignored" do
      v = vm(requested_at: 100, idle_at: 50, busy_at: 200, finished_at: 400, destroyed_at: 300)
      assert phases(v) == %{boot_s: 100, idle_s: 0, busy_s: 100, teardown_s: 0}
    end

    test "zero-length phases count nothing" do
      v = vm(requested_at: 100, idle_at: 100, busy_at: 100, finished_at: 160, destroyed_at: 160)
      assert phases(v) == %{boot_s: 0, idle_s: 0, busy_s: 60, teardown_s: 0}
    end

    test "the earlier of finished and failed starts teardown" do
      v = vm(requested_at: 0, busy_at: 10, finished_at: 70, failed_at: 40, destroyed_at: 100)
      assert phases(v) == %{boot_s: 10, idle_s: 0, busy_s: 30, teardown_s: 60}
    end

    test "mem_mib_s counts the VMM's overhead, vcpu_s the vCPUs" do
      v =
        vm([requested_at: 0, destroyed_at: 100],
          vcpus: 2,
          memory_mib: 4096,
          vmm_overhead_mib: 160
        )

      t = Tally.vm(v, @day, @day + 86_400)
      assert t.vcpu_s == 200
      assert t.mem_mib_s == (4096 + 160) * 100
    end

    test "timestamps are floored to whole seconds" do
      v =
        vm(requested_at: 0, destroyed_at: 0)
        |> Map.merge(%{
          requested_at: DateTime.from_unix!((@day + 10) * 1_000_000 + 900_000, :microsecond),
          destroyed_at: DateTime.from_unix!((@day + 20) * 1_000_000 + 100_000, :microsecond)
        })

      assert phases(v).boot_s == 10
    end

    test "a VM counts on the day it was requested, and as unused without a busy_at" do
      unused = vm(requested_at: 100, idle_at: 120, finished_at: 400, destroyed_at: 405)
      used = vm(requested_at: 100, busy_at: 120, finished_at: 400, destroyed_at: 405)
      live = vm(requested_at: 100, idle_at: 120)
      yesterday = vm(requested_at: -100, idle_at: 120, finished_at: 400, destroyed_at: 405)

      assert %{vm_count: 1, unused_count: 1} = Tally.vm(unused, @day, @day + 86_400)
      assert %{vm_count: 1, unused_count: 0} = Tally.vm(used, @day, @day + 86_400)
      assert %{vm_count: 1, unused_count: 0} = Tally.vm(live, @day, @day + 86_400)
      assert %{vm_count: 0, unused_count: 0} = Tally.vm(yesterday, @day, @day + 86_400)
    end

    test "a VM with no requested_at is skipped" do
      assert Tally.vm(vm(idle_at: 10, destroyed_at: 20), @day, @day + 86_400) == nil
    end
  end

  describe "properties" do
    defp marks_gen do
      opt = fn -> one_of([constant(nil), integer(-200..3000)]) end

      gen all(
            req <- integer(-200..3000),
            idle <- opt.(),
            busy <- opt.(),
            fin <- opt.(),
            fail <- opt.(),
            destroyed <- opt.(),
            vcpus <- integer(1..16),
            mem <- integer(256..65_536),
            over <- integer(0..512)
          ) do
        vm(
          [
            requested_at: req,
            idle_at: idle,
            busy_at: busy,
            finished_at: fin,
            failed_at: fail,
            destroyed_at: destroyed
          ],
          vcpus: vcpus,
          memory_mib: mem,
          vmm_overhead_mib: over
        )
      end
    end

    defp held(v, from, until) do
      a = DateTime.to_unix(v.requested_at)
      b = if v.destroyed_at, do: max(DateTime.to_unix(v.destroyed_at), a), else: until
      max(0, min(b, until) - max(a, from))
    end

    property "the phases add up to the held seconds inside the window" do
      check all(
              v <- marks_gen(),
              from <- integer(-300..3000),
              len <- integer(0..3500)
            ) do
        {from, until} = {@day + from, @day + from + len}
        t = Tally.vm(v, from, until)
        h = held(v, from, until)

        assert t.boot_s + t.idle_s + t.busy_s + t.teardown_s == h
        assert Enum.all?([t.boot_s, t.idle_s, t.busy_s, t.teardown_s], &(&1 >= 0))
        assert t.vcpu_s == v.vcpus * h
        assert t.mem_mib_s == (v.memory_mib + v.vmm_overhead_mib) * h
      end
    end

    property "a range counted piece by piece adds up to the whole range" do
      check all(
              v <- marks_gen(),
              cuts <- list_of(integer(-300..3300), max_length: 6)
            ) do
        points = Enum.sort(Enum.uniq([-300, 3300 | cuts]))
        {from, until} = {@day + hd(points), @day + List.last(points)}

        pieces =
          points
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, b] -> Tally.vm(v, @day + a, @day + b) end)

        assert Tally.add(pieces) == Tally.vm(v, from, until)
      end
    end
  end

  describe "a job" do
    defp job(started, completed, conclusion \\ "success"),
      do: %{
        started_at: started && at(started),
        completed_at: completed && at(completed),
        conclusion: conclusion
      }

    test "rounds each job up to the next whole minute" do
      for {s, min} <- [{0, 0}, {1, 1}, {59, 1}, {60, 1}, {61, 2}] do
        assert %{job_s: ^s, job_billable_min: ^min, job_count: 1} = Tally.job(job(100, 100 + s))
      end
    end

    test "a negative duration counts nothing, and nil times are skipped" do
      assert Tally.job(job(100, 99)) == nil
      assert Tally.job(job(nil, 99)) == nil
      assert Tally.job(job(100, nil)) == nil
    end

    test "counts successes and failures" do
      assert %{success_count: 1, failure_count: 0} = Tally.job(job(0, 10, "success"))
      assert %{success_count: 0, failure_count: 1} = Tally.job(job(0, 10, "failure"))

      assert %{success_count: 0, failure_count: 0, job_count: 1} =
               Tally.job(job(0, 10, "cancelled"))
    end
  end

  describe "a box's online time" do
    test "5 s for the first sample, then each gap, at most 15 s" do
      assert Tally.online_s([100]) == 5
      assert Tally.online_s([100, 105, 110]) == 15
      assert Tally.online_s([100, 105, 200, 203]) == 5 + 5 + 15 + 3
    end

    test "no samples gives nil" do
      assert Tally.online_s([]) == nil
    end
  end
end
