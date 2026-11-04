defmodule CrewAgent.HostMetrics do
  @moduledoc """
  Host-wide CPU, memory, swap, load and disk for `box.metrics` (§10.4):
  Linux from /proc, macOS from sysctl, vm_stat, top and df.
  """

  @type cpu :: %{total: non_neg_integer(), idle: non_neg_integer()} | nil

  @doc "One sample, and the CPU reading to pass next time."
  @spec sample(CrewAgent.Config.t(), cpu()) :: {map(), cpu()}
  def sample(config, prev) do
    {cpu_pct, cpu} = cpu(config, prev)
    mem = memory(config)
    {disk_total, disk_free} = disk(config.data_dir)
    vm_area_free = vm_area_free(config)

    {%{
       t: System.os_time(:millisecond),
       cpu_pct: cpu_pct,
       mem_used_mib: mem.used,
       mem_total_mib: mem.total,
       swap_used_mib: mem.swap_used,
       load1: load1(config),
       disk_used_mib: max(disk_total - disk_free, 0),
       disk_total_mib: disk_total,
       vm_area_free_mib: vm_area_free,
       cache_used_mib: 0,
       vms_running: CrewAgent.VMs.running_count()
     }, cpu}
  end

  # A driver whose VMs take no disk (the null driver) says what's free.
  defp vm_area_free(config) do
    driver = CrewAgent.Config.driver_module(config)

    if Code.ensure_loaded?(driver) and function_exported?(driver, :vm_area_free_mib, 0) do
      # (Dynamic: the compiler would warn that other drivers lack it.)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(driver, :vm_area_free_mib, [])
    else
      {_, free} = disk(CrewAgent.Config.vms_dir(config))
      free
    end
  end

  # -- Linux -------------------------------------------------------------------

  defp linux?, do: match?({:unix, :linux}, :os.type())

  defp cpu(config, prev) do
    if linux?() do
      cur = config.proc |> read("stat") |> cpu_times()
      {cpu_percent(prev, cur), cur}
    else
      {darwin_cpu(), nil}
    end
  end

  @doc "Total and idle (idle + iowait) jiffies from the aggregate `cpu` line."
  def cpu_times(stat) do
    with [line | _] <- Regex.run(~r/^cpu\s+(.+)$/m, stat, capture: :all_but_first),
         [user, nice, system, idle, iowait | rest] <-
           line |> String.split() |> Enum.map(&String.to_integer/1) do
      steal_irq = rest |> Enum.take(3) |> Enum.sum()
      %{total: user + nice + system + idle + iowait + steal_irq, idle: idle + iowait}
    else
      _ -> nil
    end
  end

  @doc "Busy share of CPU time between two readings, 0-100."
  def cpu_percent(%{total: t0, idle: i0}, %{total: t1, idle: i1}) when t1 > t0 do
    busy = t1 - t0 - (i1 - i0)
    Float.round(max(busy, 0) / (t1 - t0) * 100, 1)
  end

  def cpu_percent(_prev, _cur), do: 0.0

  defp memory(config) do
    if linux?(), do: linux_memory(read(config.proc, "meminfo")), else: darwin_memory()
  end

  @doc "Memory and swap in MiB from /proc/meminfo. Used is total minus MemAvailable."
  def linux_memory(meminfo) do
    kb =
      for line <- String.split(meminfo, "\n"),
          [k, v] <- [String.split(line, ":", parts: 2)],
          {n, _} <- [Integer.parse(String.trim(v))],
          into: %{},
          do: {k, n}

    total = div(kb["MemTotal"] || 0, 1024)
    available = div(kb["MemAvailable"] || 0, 1024)
    swap = div((kb["SwapTotal"] || 0) - (kb["SwapFree"] || 0), 1024)
    %{total: total, used: max(total - available, 0), swap_used: max(swap, 0)}
  end

  defp load1(config) do
    if linux?() do
      case config.proc |> read("loadavg") |> String.split() do
        [l | _] -> String.to_float(l)
        _ -> 0.0
      end
    else
      case cmd("sysctl", ["-n", "vm.loadavg"]) do
        {:ok, out} -> parse_loadavg(out)
        _ -> 0.0
      end
    end
  end

  # -- macOS ---------------------------------------------------------------------

  @doc "The 1-minute load from sysctl's `{ 3.21 2.98 2.75 }`."
  def parse_loadavg(out) do
    case Regex.run(~r/([\d.]+)/, out) do
      [_, l] -> parse_float(l)
      _ -> 0.0
    end
  end

  @doc false
  def darwin_cpu do
    case cmd("top", ["-l", "1", "-n", "0", "-s", "0"]) do
      {:ok, out} -> parse_top_idle(out)
      _ -> 0.0
    end
  end

  @doc "CPU busy % from top's `CPU usage: 3.4% user, 5.4% sys, 91.1% idle` line."
  def parse_top_idle(out) do
    case Regex.run(~r/CPU usage:.*?([\d.]+)% idle/, out) do
      [_, idle] -> Float.round(max(0.0, 100.0 - parse_float(idle)), 1)
      _ -> 0.0
    end
  end

  defp darwin_memory do
    total =
      case cmd("sysctl", ["-n", "hw.memsize"]) do
        {:ok, out} -> div(String.to_integer(String.trim(out)), 1_048_576)
        _ -> 0
      end

    free =
      case cmd("vm_stat", []) do
        {:ok, out} -> parse_vm_stat_free(out)
        _ -> 0
      end

    swap =
      case cmd("sysctl", ["-n", "vm.swapusage"]) do
        {:ok, out} ->
          case Regex.run(~r/used = ([\d.]+)M/, out) do
            [_, used] -> round(parse_float(used))
            _ -> 0
          end

        _ ->
          0
      end

    %{total: total, used: max(total - free, 0), swap_used: swap}
  end

  @doc "Free memory (free + inactive + speculative pages) in MiB from vm_stat."
  def parse_vm_stat_free(out) do
    page =
      case Regex.run(~r/page size of (\d+) bytes/, out) do
        [_, p] -> String.to_integer(p)
        _ -> 16_384
      end

    pages =
      for key <- ["Pages free", "Pages inactive", "Pages speculative"],
          [_, n] <- [Regex.run(~r/#{key}:\s+(\d+)/, out)],
          do: String.to_integer(n)

    div(Enum.sum(pages) * page, 1_048_576)
  end

  # -- both ------------------------------------------------------------------------

  @doc "`{total_mib, free_mib}` of the filesystem holding `path`."
  def disk(path) do
    case cmd("df", ["-Pk", existing(path)]) do
      {:ok, out} -> parse_df(out)
      _ -> {0, 0}
    end
  end

  def parse_df(out) do
    case out |> String.split("\n", trim: true) |> List.last() |> String.split() do
      [_fs, total, _used, avail | _] ->
        {div(String.to_integer(total), 1024), div(String.to_integer(avail), 1024)}

      _ ->
        {0, 0}
    end
  end

  defp existing(path) do
    cond do
      File.exists?(path) -> path
      path == "/" -> "/"
      true -> existing(Path.dirname(path))
    end
  end

  defp read(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, body} -> body
      _ -> ""
    end
  end

  defp cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, out}
    end
  rescue
    _ -> {:error, :enoent}
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
