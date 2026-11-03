defmodule CrewGuest.Metrics do
  @moduledoc """
  The guest's view of its resources, posted to `/v1/metrics` every 5 s
  (§13.5 step 10): CPU from `/proc/stat`, memory from `/proc/meminfo`, the
  root filesystem from `df -Pk /` (Erlang has no `statfs`), and network
  byte counters from `/proc/net/dev`.

  Off Linux (the null driver on macOS) the `/proc` files don't exist, so
  those values are 0. A failed post is dropped: the next sample replaces it.
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

    cpu = root |> Path.join("stat") |> read_file() |> parse_stat()
    {mem_total, mem_used} = root |> Path.join("meminfo") |> read_file() |> parse_meminfo()
    {rx, tx} = root |> Path.join("net/dev") |> read_file() |> parse_net_dev()

    sample = %{
      t: System.system_time(:millisecond),
      cpu_pct: cpu_pct(prev_cpu, cpu),
      mem_used_mib: mem_used,
      mem_total_mib: mem_total,
      disk_used_mib: parse_df(df.()) || 0,
      net_rx_bytes: rx,
      net_tx_bytes: tx
    }

    {sample, cpu}
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
      opts: Keyword.take(opts, [:proc_root, :df]),
      cpu: nil
    }

    {_sample, cpu} = read(state.opts, nil)
    Process.send_after(self(), :tick, state.interval)
    {:ok, %{state | cpu: cpu}}
  end

  @impl true
  def handle_info(:tick, s) do
    {sample, cpu} = read(s.opts, s.cpu)
    _ = API.post_metrics(s.client, sample)
    Process.send_after(self(), :tick, s.interval)
    {:noreply, %{s | cpu: cpu}}
  end
end
