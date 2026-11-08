defmodule Crew.Usage do
  @moduledoc """
  Job and VM minutes per box, repo and VM shape, by UTC day (§16.6).

  VM time is time held: a VM counts from `requested_at` until
  `destroyed_at`, split by phase (boot, idle, busy, teardown), and a VM
  held across midnight splits across both days. Job minutes count
  finished work: a job counts whole on the UTC day of its
  `completed_at`, never split, with its seconds and its seconds rounded
  up to whole minutes, as GitHub bills hosted runners.

  `compute/1` reads a day from the raw rows. `Crew.Usage.Rollup` stores
  closed days in `usage_days`, `usage_box_days` and `usage_rollups`,
  which outlive the job and VM rows (§9.4).

  Display only. Nothing here changes placement, labels or sizes.
  """
  import Ecto.Query

  alias Crew.{Repo, Scheduler, VMs}
  alias Crew.Boxes.Box
  alias Crew.Jobs.Job
  alias Crew.Metrics.BoxMetric
  alias Crew.Sizes.Size
  alias Crew.Usage.{BoxDay, Day, RolledDay, Tally}

  # Closed days every run recomputes: a job that finished just before
  # midnight on GitHub's clock can arrive after it.
  @recompute_days 2
  # Days without a rollup filled in per run, oldest first.
  @backfill_days 31

  @doc """
  One UTC day from the raw rows, as `%{rows: [...], boxes: [...]}`: the
  rows `usage_days` and `usage_box_days` would store for it. Today
  counts up to `now`. Reads only.
  """
  def compute(%Date{} = day, now \\ DateTime.utc_now()) do
    {from, day_end} = Tally.day_window(day)
    until = min(day_end, Tally.unix(now))
    until = max(until, from)

    vms = VMs.overlapping(from, until)
    jobs = finished_jobs(from, until)
    linked = linked_vms(jobs, vms)
    sizes = Map.new(Repo.all(Size), &{&1.id, &1})

    vm_tallies =
      for vm <- vms, t = Tally.vm(vm, from, until), do: {key(day, vm.box_id, vm.repo_id, vm), t}

    job_tallies =
      for job <- jobs, t = Tally.job(job) do
        {job_key(day, job, Map.get(linked, job.vm_id), sizes), t}
      end

    rows =
      (vm_tallies ++ job_tallies)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {key, tallies} ->
        zero = Map.new(Tally.fields(), &{&1, 0})
        Map.merge(key, Map.merge(zero, Tally.add(tallies)))
      end)
      |> Enum.reject(fn row -> Enum.all?(Tally.fields(), &(row[&1] == 0)) end)
      |> Enum.sort_by(&{&1.box_id || "", &1.repo_id, &1.vcpus || 0, &1.memory_mib || 0})

    %{rows: rows, boxes: boxes(day, rows, from, until)}
  end

  defp key(day, box_id, repo_id, shape),
    do: %{
      day: day,
      box_id: box_id,
      repo_id: repo_id,
      vcpus: shape.vcpus,
      memory_mib: shape.memory_mib
    }

  # A job's box and shape are its VM's; with no VM, no box, and its own
  # shape or its size's.
  defp job_key(day, job, %{} = vm, _sizes), do: key(day, vm.box_id, job.repo_id, vm)

  defp job_key(day, job, nil, sizes) do
    size = Map.get(sizes, job.size_id)

    key(day, nil, job.repo_id, %{
      vcpus: job.vcpus || (size && size.vcpus),
      memory_mib: job.memory_mib || (size && size.memory_mib)
    })
  end

  # Finished Crew jobs that completed in the window, on
  # jobs(classification, gh_state, completed_at).
  defp finished_jobs(from, until) do
    from(j in Job,
      where:
        j.classification == "ours" and j.gh_state == "completed" and
          j.completed_at >= ^DateTime.from_unix!(from) and
          j.completed_at < ^DateTime.from_unix!(until) and not is_nil(j.started_at),
      select:
        map(j, [
          :repo_id,
          :vm_id,
          :size_id,
          :vcpus,
          :memory_mib,
          :conclusion,
          :started_at,
          :completed_at
        ])
    )
    |> Repo.all()
  end

  # The jobs' VMs: the day's, and any that were gone before it began (a
  # late webhook can complete a job after its VM is destroyed).
  defp linked_vms(jobs, vms) do
    known = Map.new(vms, &{&1.id, &1})
    missing = for(%{vm_id: id} <- jobs, id, not Map.has_key?(known, id), do: id) |> Enum.uniq()
    Map.merge(known, Map.new(VMs.get_many(missing), &{&1.id, &1}))
  end

  # Every box with VM rows or samples that day: its online time from
  # the samples, read box by box on box_metrics(box_id, t), and its
  # capacity now.
  defp boxes(day, rows, from, until) do
    samples =
      for id <- Repo.all(from b in Box, select: b.id),
          ts =
            Repo.all(
              from m in BoxMetric,
                where: m.box_id == ^id and m.t >= ^from and m.t < ^until,
                order_by: m.t,
                select: m.t
            ),
          ts != [],
          into: %{},
          do: {id, ts}

    ids = Enum.uniq(for(%{box_id: id} <- rows, id, do: id) ++ Map.keys(samples))

    for box <- Repo.all(from b in Box, where: b.id in ^ids, order_by: b.id) do
      capacity = Scheduler.capacity(box)

      %{
        day: day,
        box_id: box.id,
        online_s: Tally.online_s(Map.get(samples, box.id, [])),
        allocatable_vcpus: capacity && capacity.vcpus,
        allocatable_memory_mib: capacity && capacity.memory_mib
      }
    end
  end

  @doc """
  Rolls up closed days (§16.6): the last 2 again, then the oldest days
  not yet rolled up, at most 31, from the first VM requested or job
  completed. Never today. Each day is replaced in one transaction.
  """
  def roll_up(today \\ Date.utc_today()) do
    recent = Enum.map(@recompute_days..1//-1, &Date.add(today, -&1))
    Enum.each(recent, &store/1)
    Enum.each(missing_days(today), &store/1)
    :ok
  end

  defp store(day) do
    %{rows: rows, boxes: boxes} = compute(day)

    {:ok, _} =
      Repo.transact(fn ->
        Repo.delete_all(from d in Day, where: d.day == ^day)
        Repo.delete_all(from b in BoxDay, where: b.day == ^day)
        # In batches: SQLite takes at most 32,766 parameters a statement.
        for batch <- Enum.chunk_every(rows, 1000), do: Repo.insert_all(Day, batch)
        for batch <- Enum.chunk_every(boxes, 1000), do: Repo.insert_all(BoxDay, batch)

        Repo.insert_all(RolledDay, [%{day: day, computed_at: DateTime.utc_now()}],
          on_conflict: {:replace, [:computed_at]},
          conflict_target: :day
        )

        {:ok, day}
      end)
  end

  # The oldest closed days with no rollup, at most @backfill_days.
  defp missing_days(today) do
    case first_day() do
      nil ->
        []

      first ->
        last = Date.add(today, -1)

        done =
          from(r in RolledDay, where: r.day >= ^first and r.day <= ^last, select: r.day)
          |> Repo.all()
          |> MapSet.new()

        if Date.compare(first, last) == :gt do
          []
        else
          Date.range(first, last)
          |> Stream.reject(&MapSet.member?(done, &1))
          |> Enum.take(@backfill_days)
        end
    end
  end

  # The day of the first VM requested or Crew job completed, each on an index.
  defp first_day do
    vm = Repo.one(from v in Crew.VMs.VM, select: type(min(v.requested_at), v.requested_at))

    job =
      Repo.one(
        from j in Job,
          where: j.classification == "ours" and j.gh_state == "completed",
          select: type(min(j.completed_at), j.completed_at)
      )

    case Enum.reject([vm, job], &is_nil/1) do
      [] -> nil
      ts -> ts |> Enum.min(DateTime) |> DateTime.to_date()
    end
  end
end
