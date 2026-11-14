defmodule Crew.Usage.Tally do
  @moduledoc """
  The arithmetic behind usage (§16.6), without the database: what one
  VM held over a window, split by phase, what one finished job counts,
  and how long a box's samples say it was online. Windows are
  `[from, until)` in Unix seconds, and every timestamp is floored to a
  whole second first, so the sums are exact integers.
  """

  @vm_fields [
    :boot_s,
    :idle_s,
    :busy_s,
    :teardown_s,
    :vcpu_s,
    :mem_mib_s,
    :vm_count,
    :unused_count
  ]
  @job_fields [:job_count, :success_count, :failure_count, :job_s, :job_billable_min]

  def fields, do: @vm_fields ++ @job_fields

  @doc "A timestamp as whole Unix seconds (floored), or nil."
  def unix(nil), do: nil
  def unix(%DateTime{} = t), do: DateTime.to_unix(t)

  @doc "A UTC day as a window: `{from, until}`."
  def day_window(%Date{} = day) do
    from = day |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    {from, from + 86_400}
  end

  @doc """
  What `vm` held over `[from, until)`: seconds in each phase, vCPU- and
  MiB-seconds, and whether it counts as requested (and unused) in the
  window. Nil for a VM with no `requested_at`.

  A VM is held from `requested_at` until `destroyed_at`, or the end of
  the window while it isn't destroyed. Its phases start at
  `requested_at` (boot), `idle_at`, `busy_at` and the earlier of
  `finished_at` and `failed_at` (teardown); each runs to the next one
  present, and the last to the end of the held span. A missing mark is
  skipped, and one earlier than the mark before it, or outside the held
  span, is ignored.
  """
  def vm(%{requested_at: nil}, _from, _until), do: nil

  def vm(vm, from, until) do
    a = unix(vm.requested_at)
    destroyed = vm.destroyed_at && max(unix(vm.destroyed_at), a)
    # A live VM's marks are checked against no end, so that where the
    # window stops doesn't change which marks count.
    b = destroyed || max(until, a)

    marks = marks(vm, a, destroyed)

    phases =
      marks
      |> Enum.reverse()
      |> Enum.chunk_every(2, 1, [{nil, b}])
      |> Map.new(fn [{phase, start}, {_, stop}] -> {phase, overlap(start, stop, from, until)} end)

    held = overlap(a, b, from, until)
    requested? = a >= from and a < until

    Map.merge(%{boot_s: 0, idle_s: 0, busy_s: 0, teardown_s: 0}, phases)
    |> Map.merge(%{
      vcpu_s: vm.vcpus * held,
      mem_mib_s: (vm.memory_mib + vm.vmm_overhead_mib) * held,
      vm_count: if(requested?, do: 1, else: 0),
      unused_count: if(requested? and destroyed != nil and is_nil(vm.busy_at), do: 1, else: 0)
    })
  end

  # Each phase's start, in order, without the ones skipped or ignored:
  # missing, outside the held span, or earlier than the one before.
  defp marks(vm, a, destroyed) do
    teardown =
      case Enum.reject([unix(vm.finished_at), unix(vm.failed_at)], &is_nil/1) do
        [] -> nil
        ts -> Enum.min(ts)
      end

    [boot_s: a, idle_s: unix(vm.idle_at), busy_s: unix(vm.busy_at), teardown_s: teardown]
    |> Enum.filter(fn {_phase, t} ->
      t != nil and t >= a and (is_nil(destroyed) or t <= destroyed)
    end)
    |> Enum.reduce([], fn
      {_phase, t}, [{_, prev} | _] = kept when t < prev -> kept
      mark, kept -> [mark | kept]
    end)
  end

  defp overlap(a, b, from, until), do: max(0, min(b, until) - max(a, from))

  @doc """
  What a finished job counts: its seconds, rounded up to whole minutes
  as GitHub bills it, and its conclusion. Nil without both times, or
  for a negative duration.
  """
  def job(%{started_at: %DateTime{} = started, completed_at: %DateTime{} = completed} = job) do
    case unix(completed) - unix(started) do
      s when s < 0 ->
        nil

      s ->
        %{
          job_count: 1,
          success_count: if(job.conclusion == "success", do: 1, else: 0),
          failure_count: if(job.conclusion == "failure", do: 1, else: 0),
          job_s: s,
          job_billable_min: div(s + 59, 60)
        }
    end
  end

  def job(_job), do: nil

  @doc """
  How long a box was online, from its samples' times (Unix seconds,
  oldest first), weighted as job coverage weighs a VM's (§16.5). Nil
  with no samples.
  """
  def online_s([]), do: nil

  def online_s(ts),
    do: ts |> Enum.map(&%{t: &1}) |> Crew.Metrics.weights() |> Enum.sum_by(&elem(&1, 1))

  @doc "Counters added up field by field; nils are skipped."
  def add(tallies) do
    tallies
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn t, acc -> Map.merge(acc, t, fn _k, x, y -> x + y end) end)
  end
end
