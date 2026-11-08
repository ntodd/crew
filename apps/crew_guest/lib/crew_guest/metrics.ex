defmodule CrewGuest.Metrics do
  @moduledoc """
  The guest's view of its resources, posted to `/v1/metrics` every 5 s
  (§13.5 step 10): CPU from `/proc/stat`, memory from `/proc/meminfo`, the
  root filesystem from `df -Pk /` (Erlang has no `statfs`), network byte
  counters from `/proc/net/dev`, the kernel's OOM kill count from
  `/proc/vmstat`, and stall totals from `/proc/pressure` (§16.5).

  Memory is also read every second between posts, and each post carries
  the most used since the last one (`mem_peak_mib`): a spike shorter than
  the interval would fall between samples otherwise.

  Off Linux (the null driver on macOS) the `/proc` files don't exist, so
  those values are 0, and the newer readings aren't sent at all. A failed
  post is dropped: the next sample replaces it.

  Nothing here may crash: the job's supervisor gives up after ten restarts
  in a minute, and a metrics bug must never fail a job. Each reading is
  taken on its own, and one that raises costs only itself.
  """

  use GenServer

  alias CrewGuest.API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Takes a sample. `prev_cpu` is the previous `/proc/stat` reading."
  def sample(opts \\ [], prev_cpu \\ nil) do
    {sample, _cpu} = read(opts, prev_cpu)
    sample
  end

  defp read(opts, prev_cpu) do
    root = Keyword.get(opts, :proc_root, "/proc")
    df = Keyword.get(opts, :df, &df/0)
    proc = &read_file(Path.join(root, &1))

    cpu = safely(fn -> parse_stat(proc.("stat")) end, nil)
    {mem_total, mem_used} = read_meminfo(root)
    {rx, tx} = safely(fn -> parse_net_dev(proc.("net/dev")) end, {0, 0})
    cpu_stall = safely(fn -> parse_pressure(proc.("pressure/cpu")) end, %{})
    mem_stall = safely(fn -> parse_pressure(proc.("pressure/memory")) end, %{})

    sample =
      %{
        t: System.system_time(:millisecond),
        cpu_pct: safely(fn -> cpu_pct(prev_cpu, cpu) end, 0.0),
        mem_used_mib: mem_used,
        mem_total_mib: mem_total,
        disk_used_mib: safely(fn -> parse_df(df.()) end, nil) || 0,
        net_rx_bytes: rx,
        net_tx_bytes: tx
      }
      |> put_known(:oom_kills, safely(fn -> parse_vmstat_oom(proc.("vmstat")) end, nil))
      |> put_known(:cpu_some_us, cpu_stall[:some])
      |> put_known(:mem_some_us, mem_stall[:some])
      |> put_known(:mem_full_us, mem_stall[:full])

    {sample, cpu}
  end

  defp read_meminfo(root),
    do: safely(fn -> root |> Path.join("meminfo") |> read_file() |> parse_meminfo() end, {0, 0})

  defp put_known(sample, _key, nil), do: sample
  defp put_known(sample, key, value), do: Map.put(sample, key, value)

  defp safely(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @doc "`{busy, total}` jiffies from `/proc/stat`'s aggregate `cpu` line."
  def parse_stat(stat) do
    with "cpu " <> rest <- stat |> String.split("\n", parts: 2) |> hd(),
         [user, nice, system, idle, iowait, irq, softirq, steal | _] <- integers(rest) do
      total = user + nice + system + idle + iowait + irq + softirq + steal
      {total - idle - iowait, total}
    else
      _ -> nil
    end
  end

  @doc "CPU use between two `/proc/stat` readings, in percent."
  def cpu_pct({busy0, total0}, {busy1, total1}) when total1 > total0,
    do: Float.round((busy1 - busy0) / (total1 - total0) * 100, 1)

  def cpu_pct(_prev, _cur), do: 0.0

  @doc "`{total_mib, used_mib}`, where used is total less available."
  def parse_meminfo(meminfo) do
    fields =
      for line <- String.split(meminfo, "\n"),
          [key, value] <- [String.split(line, ":", parts: 2)],
          [kib | _] <- [integers(value)],
          into: %{},
          do: {key, kib}

    case fields do
      %{"MemTotal" => total, "MemAvailable" => available} ->
        {div(total, 1024), div(max(total - available, 0), 1024)}

      _ ->
        {0, 0}
    end
  end

  @doc """
  `{rx_bytes, tx_bytes}`: eth0's counters, or, without an eth0, the sum
  over every interface but `lo`. Docker's bridges and veths would count
  container traffic twice, so eth0 alone is preferred.
  """
  def parse_net_dev(dev) do
    ifaces =
      for line <- dev |> String.split("\n") |> Enum.drop(2),
          [name, counters] <- [String.split(line, ":", parts: 2)],
          [rx, _, _, _, _, _, _, _, tx | _] <- [integers(counters)],
          do: {String.trim(name), rx, tx}

    case Enum.find(ifaces, &(elem(&1, 0) == "eth0")) do
      {_, rx, tx} ->
        {rx, tx}

      nil ->
        ifaces
        |> Enum.reject(&(elem(&1, 0) == "lo"))
        |> Enum.reduce({0, 0}, fn {_, rx, tx}, {a, b} -> {a + rx, b + tx} end)
    end
  end

  @doc "The kernel's OOM kill count since boot, from `/proc/vmstat` (Linux 4.13 and later)."
  def parse_vmstat_oom(vmstat) do
    vmstat
    |> String.split("\n")
    |> Enum.find_value(fn
      "oom_kill " <> n -> non_neg(String.trim(n))
      _ -> nil
    end)
  end

  @doc """
  The `some` and `full` stall totals, in microseconds, from a
  `/proc/pressure` file. A line that's missing or doesn't parse is left
  out.
  """
  def parse_pressure(text) do
    for line <- String.split(text, "\n"),
        [kind | fields] <- [String.split(line)],
        kind in ["some", "full"],
        "total=" <> total <- fields,
        n = non_neg(total),
        into: %{},
        do: {if(kind == "some", do: :some, else: :full), n}
  end

  defp non_neg(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  @doc "Used MiB of `/` from `df -Pk /`."
  def parse_df(output) do
    with [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, _blocks, used | _] <- String.split(line),
         {used, ""} <- Integer.parse(used) do
      div(used, 1024)
    else
      _ -> nil
    end
  end

  defp integers(text) do
    text
    |> String.split()
    |> Enum.map(&Integer.parse/1)
    |> Enum.take_while(&match?({_, ""}, &1))
    |> Enum.map(&elem(&1, 0))
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  defp df do
    case System.cmd("df", ["-Pk", "/"], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  rescue
    _ -> ""
  end

  # Server

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      interval: Keyword.get(opts, :interval_ms, 5_000),
      peek: Keyword.get(opts, :peek_ms, 1_000),
      opts: Keyword.take(opts, [:proc_root, :df]),
      cpu: nil,
      peak: nil,
      posting: nil
    }

    {_sample, cpu} = read(state.opts, nil)
    Process.send_after(self(), :tick, state.interval)
    Process.send_after(self(), :peek, state.peek)
    {:ok, %{state | cpu: cpu}}
  end

  # A post goes from its own process, one at a time, so a slow one doesn't
  # hold up the memory reads. One due while another is in flight is
  # skipped, and its peak kept for the next.
  @impl true
  def handle_info(:tick, %{posting: nil} = s) do
    Process.send_after(self(), :tick, s.interval)
    {sample, cpu} = read(s.opts, s.cpu)
    sample = put_known(sample, :mem_peak_mib, peak(s.peak, sample))
    client = s.client

    {_pid, ref} =
      spawn_monitor(fn -> safely(fn -> API.post_metrics(client, sample) end, :error) end)

    {:noreply, %{s | cpu: cpu, peak: nil, posting: ref}}
  end

  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, s.interval)
    {:noreply, s}
  end

  def handle_info(:peek, s) do
    Process.send_after(self(), :peek, s.peek)
    {total, used} = read_meminfo(Keyword.get(s.opts, :proc_root, "/proc"))
    {:noreply, %{s | peak: if(total > 0, do: max(s.peak || used, used), else: s.peak)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{posting: ref} = s),
    do: {:noreply, %{s | posting: nil}}

  def handle_info(_msg, s), do: {:noreply, s}

  # The most used since the last post, counting this post's own reading;
  # nil when memory couldn't be read at all.
  defp peak(nil, %{mem_total_mib: 0}), do: nil
  defp peak(nil, sample), do: sample.mem_used_mib
  defp peak(peak, %{mem_total_mib: 0}), do: peak
  defp peak(peak, sample), do: max(peak, sample.mem_used_mib)
end
