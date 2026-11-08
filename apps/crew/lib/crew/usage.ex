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

  alias Crew.{Repo, Repos, Scheduler, Scope, Sizes, VMs}
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
  # The pairs top_jobs/3 keeps.
  @top_jobs 10

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
    jobs = finished_jobs(from, day_end)
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

  # -- reads -------------------------------------------------------------------

  @doc """
  Usage from `from` to `to` (UTC days, both included; never past today)
  for `scope`: `totals`, a `series` with every day, and breakdowns by
  box, repo and shape, each with `vm_s` (the four phases added up).

  Closed days come from the stored tables; today, and a closed day the
  rollup hasn't stored yet within its last 2, are computed live and
  cached for the dashboard's `chart_cache_ms`. Older closed days it
  hasn't stored yet are listed in `pending` and count nothing.

  Everyone sees the fleet and every box in full: box pages already show
  every box's whole allocation. In `repos`, someone who isn't an admin
  sees only the repos they can read; the rest add up into one row with
  `repo: nil`. Archived repos and revoked boxes count like any other.

  Options:

    * `box_id:` only that box's rows.
    * `repo_id:` only that repo's rows, and nothing for a scope that
      can't read it. Box use is left out: it's the whole box's.
    * `others: :each` gives each repo the scope can't read a `repo: nil`
      row of its own, as a box's page names each VM's.
    * `sort: :vm_s` orders `repos` by VM time, not job time.
  """
  def summary(%Scope{} = scope, %Date{} = from, %Date{} = to, opts \\ []) do
    {to, days} = days(from, to)

    days =
      if opts[:repo_id] && not Repos.can_read?(scope, opts[:repo_id]), do: [], else: days

    {rows, box_days, pending} =
      load(days, Date.utc_today(), Keyword.take(opts, [:box_id, :repo_id]))

    sizes = Sizes.list()

    %{
      from: from,
      to: to,
      pending: pending,
      totals: total(rows),
      series: series(days, rows),
      boxes: by_box(rows, box_days),
      repos: by_repo(rows, Repos.readable_ids(scope), opts),
      shapes: by_shape(rows, sizes)
    }
  end

  @doc """
  The fleet's totals for each day from `from` to `to`, as `summary/3`'s
  `series`, without the breakdowns: everyone may see them.
  """
  def daily(%Date{} = from, %Date{} = to) do
    {_to, days} = days(from, to)
    {rows, _box_days, _pending} = load(days, Date.utc_today(), [])
    series(days, rows)
  end

  defp days(from, to) do
    to = Enum.min([to, Date.utc_today()], Date)
    {to, if(Date.compare(from, to) == :gt, do: [], else: Enum.to_list(Date.range(from, to)))}
  end

  defp series(days, rows) do
    by_day = Enum.group_by(rows, & &1.day)
    Enum.map(days, &(by_day |> Map.get(&1, []) |> total() |> Map.put(:day, &1)))
  end

  # The days' rows and box days, stored or live, and the closed days
  # still waiting for the rollup.
  defp load([], _today, _filter), do: {[], [], []}

  defp load(days, today, filter) do
    {from, to} = {List.first(days), List.last(days)}

    stored =
      from(r in RolledDay, where: r.day >= ^from and r.day <= ^to, select: r.day)
      |> Repo.all()
      |> MapSet.new()

    live_since = Date.add(today, -@recompute_days)

    {live, missing} =
      days
      |> Enum.reject(&MapSet.member?(stored, &1))
      |> Enum.split_with(&(Date.compare(&1, live_since) != :lt))

    pending =
      case missing != [] and first_day() do
        %Date{} = first -> Enum.filter(missing, &(Date.compare(&1, first) != :lt))
        _ -> []
      end

    computed = Enum.map(live, &cached/1)

    # Only the days found stored above: one stored since then is already
    # among the live ones.
    stored_days = MapSet.to_list(stored)

    rows =
      from(d in Day, where: d.day in ^stored_days)
      |> where(^filter)
      |> Repo.all()
      |> Enum.map(&plain/1)

    box_days =
      if filter[:repo_id] do
        []
      else
        from(b in BoxDay, where: b.day in ^stored_days)
        |> where(^filter)
        |> Repo.all()
        |> Enum.map(&plain/1)
      end

    live_rows = computed |> Enum.flat_map(& &1.rows) |> Enum.filter(&matches?(&1, filter))

    live_box_days =
      if filter[:repo_id],
        do: [],
        else: computed |> Enum.flat_map(& &1.boxes) |> Enum.filter(&matches?(&1, filter))

    {rows ++ live_rows, box_days ++ live_box_days, pending}
  end

  defp matches?(row, filter), do: Enum.all?(filter, fn {k, v} -> Map.get(row, k) == v end)

  defp cached(day) do
    ttl = Application.get_env(:crew, :chart_cache_ms, 30_000)
    Crew.Cache.fetch({__MODULE__, day}, ttl, fn -> compute(day) end)
  end

  defp plain(struct), do: struct |> Map.from_struct() |> Map.delete(:__meta__)

  defp total(rows) do
    t =
      Map.merge(
        Map.new(Tally.fields(), &{&1, 0}),
        Tally.add(Enum.map(rows, &Map.take(&1, Tally.fields())))
      )

    Map.put(t, :vm_s, t.boot_s + t.idle_s + t.busy_s + t.teardown_s)
  end

  # Every box with rows or box days, the most VM time first. Use is the
  # day-weighted share of what it offered while online, over the days
  # that have both.
  defp by_box(rows, box_days) do
    rows_by = Enum.group_by(rows, & &1.box_id)
    days_by = Enum.group_by(box_days, & &1.box_id)
    ids = Enum.uniq(Enum.reject(Map.keys(rows_by), &is_nil/1) ++ Map.keys(days_by))
    boxes = Repo.all(from b in Box, where: b.id in ^ids)

    named =
      for box <- boxes do
        rows = Map.get(rows_by, box.id, [])
        days = Map.get(days_by, box.id, [])
        online = days |> Enum.map(& &1.online_s) |> Enum.reject(&is_nil/1)

        rows
        |> total()
        |> Map.merge(%{
          box: box,
          online_s: if(online == [], do: nil, else: Enum.sum(online)),
          mem_use: use(rows, days, :mem_mib_s, :allocatable_memory_mib),
          vcpu_use: use(rows, days, :vcpu_s, :allocatable_vcpus)
        })
      end
      |> Enum.sort_by(&{-&1.vm_s, &1.box.name})

    case Map.get(rows_by, nil) do
      nil ->
        named

      rows ->
        named ++
          [rows |> total() |> Map.merge(%{box: nil, online_s: nil, mem_use: nil, vcpu_use: nil})]
    end
  end

  defp use(rows, days, used, offered) do
    {num, den} =
      Enum.reduce(days, {0, 0}, fn d, {num, den} ->
        case {d.online_s, Map.get(d, offered)} do
          {o, c} when is_number(o) and o > 0 and is_number(c) and c > 0 ->
            day_used = rows |> Enum.filter(&(&1.day == d.day)) |> Enum.sum_by(&Map.get(&1, used))
            {num + day_used, den + c * o}

          _ ->
            {num, den}
        end
      end)

    if den > 0, do: num / den
  end

  defp by_repo(rows, readable, opts) do
    repos = Map.new(Repos.list_all(), &{&1.id, &1})
    {mine, others} = Enum.split_with(rows, &(readable == :all or &1.repo_id in readable))
    order = if opts[:sort] == :vm_s, do: &{-&1.vm_s, -&1.job_s}, else: &{-&1.job_s, -&1.vm_s}

    named =
      mine
      |> Enum.group_by(& &1.repo_id)
      |> Enum.flat_map(fn {id, rows} ->
        case Map.get(repos, id) do
          nil -> []
          repo -> [rows |> total() |> Map.put(:repo, repo)]
        end
      end)
      |> Enum.sort_by(&Tuple.insert_at(order.(&1), 2, &1.repo.full_name))

    hidden =
      cond do
        others == [] ->
          []

        opts[:others] == :each ->
          others
          |> Enum.group_by(& &1.repo_id)
          |> Enum.map(fn {_id, rows} -> rows |> total() |> Map.put(:repo, nil) end)

        true ->
          [others |> total() |> Map.put(:repo, nil)]
      end

    # Named one by one, they all sort together.
    if opts[:others] == :each,
      do: Enum.sort_by(named ++ hidden, order),
      else: named ++ hidden
  end

  defp by_shape(rows, sizes) do
    rows
    |> Enum.group_by(&{&1.vcpus, &1.memory_mib})
    |> Enum.map(fn {{vcpus, memory}, rows} ->
      rows
      |> total()
      |> Map.put(:shape, %{
        name: size_name(sizes, vcpus, memory),
        vcpus: vcpus,
        memory_mib: memory
      })
    end)
    |> Enum.sort_by(&{&1.shape.memory_mib || 0, &1.shape.vcpus || 0})
  end

  # The size a shape matches, a live one first.
  defp size_name(sizes, vcpus, memory) do
    matching = Enum.filter(sizes, &(&1.vcpus == vcpus and &1.memory_mib == memory))

    case Enum.find(matching, &is_nil(&1.retired_at)) || List.first(matching) do
      nil -> nil
      size -> size.name
    end
  end

  @doc """
  The 10 `(workflow_name, name)` pairs of `repo` with the most job
  minutes over the last `days` UTC days, today among them, read from
  `jobs` (the rollup keeps no job names), with their counts and
  rounded-up minutes. Nothing for a scope that can't read the repo.
  """
  def top_jobs(%Scope{} = scope, repo, days \\ 30) do
    if Repos.can_read?(scope, repo.id) do
      since = Date.utc_today() |> Date.add(1 - days) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

      from(j in Job,
        where:
          j.repo_id == ^repo.id and j.completed_at >= ^since and j.classification == "ours" and
            j.gh_state == "completed",
        select: map(j, [:workflow_name, :name, :conclusion, :started_at, :completed_at])
      )
      |> Repo.all()
      |> Enum.group_by(&{&1.workflow_name, &1.name})
      |> Enum.flat_map(fn {{workflow, name}, jobs} ->
        case jobs |> Enum.map(&Tally.job/1) |> Tally.add() do
          %{job_count: n} = t ->
            [
              %{
                workflow_name: workflow,
                name: name,
                jobs: n,
                job_s: t.job_s,
                job_billable_min: t.job_billable_min
              }
            ]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(&{-&1.job_s, &1.workflow_name || "", &1.name || ""})
      |> Enum.take(@top_jobs)
    else
      []
    end
  end
end
