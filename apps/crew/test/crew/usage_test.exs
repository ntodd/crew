defmodule Crew.UsageTest do
  use Crew.DataCase
  use ExUnitProperties

  alias Crew.Usage
  alias Crew.Usage.{BoxDay, Day, RolledDay}

  @day ~D[2026-11-03]
  # 2026-11-03 00:00:00 UTC
  @t0 1_793_664_000

  defp at(s), do: DateTime.from_unix!((@t0 + s) * 1_000_000, :microsecond)

  defp job_fixture(repo, attrs) do
    Repo.insert!(
      struct!(
        %Crew.Jobs.Job{
          repo_id: repo.id,
          github_id: unique(),
          github_run_id: unique(),
          classification: "ours",
          gh_state: "completed",
          conclusion: "success",
          runner_name: "crew-runner",
          seen_at: at(0),
          size_id: Repo.get_by!(Crew.Sizes.Size, name: "m").id
        },
        attrs
      )
    )
  end

  defp row(rows, key), do: Enum.find(rows, &(Map.take(&1, Map.keys(key)) == key))

  setup do
    repo = repo_fixture()
    box = box_fixture()
    %{repo: repo, box: box}
  end

  describe "compute/1, VMs" do
    test "a day's VM time by box, repo and shape", %{repo: repo, box: box} do
      vm_fixture(box,
        repo_id: repo.id,
        vcpus: 2,
        memory_mib: 4096,
        vmm_overhead_mib: 100,
        requested_at: at(100),
        idle_at: at(130),
        busy_at: at(200),
        finished_at: at(800),
        destroyed_at: at(810),
        state: "destroyed"
      )

      vm_fixture(box,
        repo_id: repo.id,
        vcpus: 2,
        memory_mib: 4096,
        vmm_overhead_mib: 100,
        requested_at: at(1000),
        idle_at: at(1010),
        finished_at: at(1100),
        destroyed_at: at(1105),
        state: "destroyed"
      )

      %{rows: [row]} = Usage.compute(@day)

      assert row.day == @day
      assert {row.box_id, row.repo_id, row.vcpus, row.memory_mib} == {box.id, repo.id, 2, 4096}

      assert Map.take(row, [:vm_count, :unused_count, :boot_s, :idle_s, :busy_s, :teardown_s]) ==
               %{
                 vm_count: 2,
                 unused_count: 1,
                 boot_s: 40,
                 idle_s: 160,
                 busy_s: 600,
                 teardown_s: 15
               }

      assert row.vcpu_s == 2 * 815
      assert row.mem_mib_s == 4196 * 815
      assert row.job_count == 0
    end

    test "a VM spanning midnight splits across both days", %{box: box} do
      vm_fixture(box,
        requested_at: at(86_000),
        busy_at: at(86_100),
        finished_at: at(87_000),
        destroyed_at: at(87_010)
      )

      %{rows: [today]} = Usage.compute(@day)
      %{rows: [tomorrow]} = Usage.compute(Date.add(@day, 1))

      assert {today.boot_s, today.busy_s, today.vm_count} == {100, 300, 1}
      assert {tomorrow.busy_s, tomorrow.teardown_s, tomorrow.vm_count} == {600, 10, 0}
    end

    test "today counts a live VM up to now", %{box: box} do
      vm_fixture(box, requested_at: at(1000), busy_at: at(1100))

      %{rows: [row]} = Usage.compute(@day, at(2000))
      assert {row.boot_s, row.busy_s} == {100, 900}
    end
  end

  describe "compute/1, jobs" do
    test "only finished Crew jobs with both times count", %{repo: repo} do
      job_fixture(repo, started_at: at(100), completed_at: at(161))
      job_fixture(repo, started_at: at(100), completed_at: at(100), conclusion: "failure")
      job_fixture(repo, classification: "not_ours", started_at: at(100), completed_at: at(200))
      job_fixture(repo, gh_state: "in_progress", started_at: at(100), completed_at: at(200))
      job_fixture(repo, started_at: nil, completed_at: at(200))
      job_fixture(repo, started_at: at(300), completed_at: at(200))

      %{rows: [row]} = Usage.compute(@day)

      assert Map.take(row, [:job_count, :success_count, :failure_count, :job_s, :job_billable_min]) ==
               %{job_count: 2, success_count: 1, failure_count: 1, job_s: 61, job_billable_min: 2}
    end

    test "a job no runner took counts nothing", %{repo: repo} do
      # GitHub stamps started_at on a job cancelled in the queue too, so
      # its wait would count as work.
      job_fixture(repo, started_at: at(100), completed_at: at(161))

      job_fixture(repo,
        runner_name: nil,
        conclusion: "cancelled",
        started_at: at(0),
        completed_at: at(9000)
      )

      job_fixture(repo,
        runner_name: "",
        conclusion: "cancelled",
        started_at: at(0),
        completed_at: at(9000)
      )

      assert %{rows: [%{job_count: 1, job_s: 61, job_billable_min: 2}]} = Usage.compute(@day)
    end

    test "a job counts whole on the day it completed", %{repo: repo} do
      job_fixture(repo, started_at: at(-600), completed_at: at(60))
      job_fixture(repo, started_at: at(86_000), completed_at: at(86_460))

      assert %{rows: [%{job_s: 660, job_count: 1}]} = Usage.compute(@day)
      assert %{rows: [%{job_s: 460, job_count: 1}]} = Usage.compute(Date.add(@day, 1))
    end

    test "a job takes its box and shape from its VM", %{repo: repo, box: box} do
      vm =
        vm_fixture(box,
          repo_id: repo.id,
          vcpus: 8,
          memory_mib: 16_384,
          requested_at: at(0),
          busy_at: at(10),
          finished_at: at(100),
          destroyed_at: at(110)
        )

      job_fixture(repo, vm_id: vm.id, vcpus: 2, started_at: at(10), completed_at: at(100))

      %{rows: [row]} = Usage.compute(@day)
      assert {row.box_id, row.vcpus, row.memory_mib, row.job_count} == {box.id, 8, 16_384, 1}
    end

    test "a job with no VM counts under no box, on its own shape or its size's", %{repo: repo} do
      job_fixture(repo, vcpus: 2, memory_mib: 4096, started_at: at(0), completed_at: at(60))
      job_fixture(repo, started_at: at(0), completed_at: at(120))

      %{rows: rows} = Usage.compute(@day)
      m = Repo.get_by!(Crew.Sizes.Size, name: "m")

      assert %{job_s: 60, box_id: nil} = row(rows, %{vcpus: 2, memory_mib: 4096})
      assert %{job_s: 120, box_id: nil} = row(rows, %{vcpus: m.vcpus, memory_mib: m.memory_mib})
    end
  end

  describe "compute/1, boxes" do
    test "online time from the day's samples, and capacity", %{box: box} do
      for t <- [-3, 0, 5, 10, 100, 103, 86_400], do: box_metric_fixture(box, @t0 + t)

      %{boxes: [b]} = Usage.compute(@day)
      cap = Crew.Scheduler.capacity(box)

      assert b.box_id == box.id
      assert b.online_s == 5 + 5 + 5 + 15 + 3
      assert {b.allocatable_vcpus, b.allocatable_memory_mib} == {cap.vcpus, cap.memory_mib}
    end

    test "no samples gives nil, and so does no capacity", %{box: box} do
      bare = box_fixture(pinned_capabilities: nil)
      vm_fixture(bare, requested_at: at(0), destroyed_at: at(10))
      vm_fixture(box, requested_at: at(0), destroyed_at: at(10))

      %{boxes: boxes} = Usage.compute(@day)

      assert %{online_s: nil, allocatable_vcpus: nil, allocatable_memory_mib: nil} =
               Enum.find(boxes, &(&1.box_id == bare.id))

      assert %{online_s: nil, allocatable_vcpus: v} = Enum.find(boxes, &(&1.box_id == box.id))
      assert is_number(v)
    end
  end

  describe "against provisioned_series/3" do
    property "vcpu_s and mem_mib_s are its integral over the same range" do
      check all(
              spans <-
                list_of(
                  tuple({integer(0..7200), integer(0..7200), boolean(), integer(1..8)}),
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 25
            ) do
        Repo.delete_all(Crew.VMs.VM)
        box = box_fixture()

        for {a, len, gone?, vcpus} <- spans do
          vm_fixture(box,
            vcpus: vcpus,
            memory_mib: vcpus * 1024,
            requested_at: at(a),
            destroyed_at: if(gone?, do: at(a + len))
          )
        end

        {since, until} = {@t0 + 600, @t0 + 6600}
        series = Crew.VMs.provisioned_series(since, until, 600)

        {v, m} =
          series
          |> Map.get(box.id, [])
          |> Enum.drop(-1)
          |> Enum.reduce({0.0, 0.0}, fn {t, v, m}, {vs, ms} ->
            dt = min(t + 600, until) - t
            {vs + v * dt, ms + m * dt}
          end)

        totals =
          for vm <- Repo.all(Crew.VMs.VM) do
            Crew.Usage.Tally.vm(vm, since, until)
          end
          |> Crew.Usage.Tally.add()

        assert round(v) == totals.vcpu_s
        assert round(m) == totals.mem_mib_s
      end
    end
  end

  describe "roll_up/1" do
    defp stored do
      %{
        days:
          Day |> Repo.all() |> Enum.map(&Map.drop(&1, [:__meta__])) |> Enum.sort_by(&inspect/1),
        boxes:
          BoxDay
          |> Repo.all()
          |> Enum.map(&Map.drop(&1, [:__meta__]))
          |> Enum.sort_by(&inspect/1),
        rolled: RolledDay |> Repo.all() |> Enum.map(& &1.day) |> Enum.sort(Date)
      }
    end

    defp rolled, do: stored().rolled

    test "stores what compute/1 gives, and twice gives the same rows", %{repo: repo, box: box} do
      vm_fixture(box,
        repo_id: repo.id,
        requested_at: at(100),
        busy_at: at(200),
        destroyed_at: at(900)
      )

      job_fixture(repo, started_at: at(200), completed_at: at(800))
      box_metric_fixture(box, @t0 + 50)

      today = Date.add(@day, 1)
      :ok = Usage.roll_up(today)
      first = stored()
      %{rows: rows, boxes: boxes} = Usage.compute(@day)

      assert Enum.map(first.days, &Map.from_struct/1) |> Enum.sort_by(&inspect/1) ==
               Enum.sort_by(rows, &inspect/1)

      assert [%{online_s: 5}] = first.boxes
      assert length(boxes) == 1

      :ok = Usage.roll_up(today)
      assert stored() == first
    end

    test "never rolls up today, and marks empty days", %{box: box} do
      vm_fixture(box, requested_at: at(0), destroyed_at: at(10))

      :ok = Usage.roll_up(Date.add(@day, 3))
      assert rolled() == Enum.map(0..2, &Date.add(@day, &1))
      assert Repo.aggregate(Day, :count) == 1
    end

    test "recomputes the last 2 closed days, and no older ones", %{box: box} do
      vm_fixture(box, requested_at: at(0), destroyed_at: at(10))
      today = Date.add(@day, 5)
      :ok = Usage.roll_up(today)

      for d <- [-1, -2, -3] do
        vm_fixture(box,
          requested_at: DateTime.add(at(0), (5 + d) * 86_400),
          destroyed_at: DateTime.add(at(0), (5 + d) * 86_400 + 10)
        )
      end

      :ok = Usage.roll_up(today)

      days = Day |> Repo.all() |> Enum.map(& &1.day) |> Enum.sort(Date)
      assert days == [@day, Date.add(today, -2), Date.add(today, -1)]
    end

    test "backfills 31 days a run, oldest first", %{box: box} do
      today = Date.add(@day, 70)
      vm_fixture(box, requested_at: at(0), destroyed_at: at(10))

      :ok = Usage.roll_up(today)
      first = rolled()
      assert length(first) == 33
      assert Enum.take(first, 31) == Enum.map(0..30, &Date.add(@day, &1))
      assert Enum.take(first, -2) == [Date.add(today, -2), Date.add(today, -1)]

      :ok = Usage.roll_up(today)
      assert length(rolled()) == 64

      :ok = Usage.roll_up(today)
      assert rolled() == Enum.map(0..69, &Date.add(@day, &1))
    end

    test "the earliest job starts the backfill too", %{repo: repo} do
      job_fixture(repo, started_at: at(0), completed_at: at(60))
      :ok = Usage.roll_up(Date.add(@day, 4))
      assert hd(rolled()) == @day
    end

    test "with nothing to count, only the last 2 days" do
      :ok = Usage.roll_up(@day)
      assert rolled() == [Date.add(@day, -2), Date.add(@day, -1)]
    end
  end

  test "the worker rolls up through yesterday" do
    assert :ok = perform_job(Crew.Usage.Rollup, %{})

    assert RolledDay |> Repo.all() |> Enum.map(& &1.day) |> Enum.max(Date) ==
             Date.add(Date.utc_today(), -1)
  end

  defp perform_job(worker, args), do: Oban.Testing.perform_job(worker, args, repo: Crew.Repo)
end
