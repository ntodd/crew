defmodule CrewAgent.DiskWatchdog do
  @moduledoc "Checks the clone and image areas every ten seconds (§12.5)."
  use GenServer
  alias CrewAgent.{Config, HostMetrics, Images, Reporter, VM}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def reserve(%{driver: "vz"} = config, id, gib),
    do: GenServer.call(__MODULE__, {:reserve, config, id, gib}, :infinity)

  def reserve(_config, _id, _gib), do: :ok

  @impl true
  def init(opts) do
    Process.send_after(self(), :check, 10_000)
    {:ok, %{reserved: %{}, disk: Keyword.get(opts, :disk, &HostMetrics.disk/1)}}
  end

  @impl true
  def handle_call({:reserve, config, id, gib}, {pid, _}, state) do
    {_, free} = state.disk.(Config.vms_dir(config))
    # Include VMs being adopted after a restart and simultaneous starts
    # whose vm.json hasn't been written yet.
    existing = for {other, dir} <- live_dirs(config), into: %{}, do: {other, disk_gib(dir)}

    active =
      for {other, {size, _}} <- state.reserved,
          not File.exists?(Path.join(Config.vm_dir(config, other), "exited.json")),
          into: %{},
          do: {other, size}

    sizes = existing |> Map.merge(active) |> Map.put(id, gib) |> Map.values()

    if Enum.sum(sizes) * 1024 <= free do
      {:reply, :ok, put_in(state.reserved[id], {gib, Process.monitor(pid)})}
    else
      {:reply, {:error, :no_capacity}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {:noreply,
     %{state | reserved: Map.reject(state.reserved, fn {_, {_, mon}} -> mon == ref end)}}
  end

  def handle_info(:check, state) do
    config = Config.get()

    if config.driver in ["vz", "firecracker"] do
      check_clones(config, state.disk)

      if image_pressure?(config, state.disk) do
        Reporter.report_pressure(Images.oldest_first(config))
      end
    end

    Process.send_after(self(), :check, 10_000)
    {:noreply, state}
  end

  def check_clones(config, disk) do
    if low?(disk.(Config.vms_dir(config)), 5) do
      clones =
        for {id, dir} <- live_dirs(config),
            pid = VM.whereis(id),
            {:ok, blocks} <- [allocated(Path.join(dir, "rootfs.ext4"))],
            do: {blocks, id, pid}

      case Enum.max(clones, fn -> nil end) do
        {_, id, pid} -> send(pid, {:kill_disk, id})
        nil -> :ok
      end
    end
  end

  def image_pressure?(config, disk \\ &HostMetrics.disk/1),
    do: low?(disk.(Config.images_dir(config)), 10)

  defp low?({total, free}, pct), do: total > 0 and free * 100 < total * pct

  defp allocated(path) do
    flags = if :os.type() == {:unix, :darwin}, do: ["-f", "%b"], else: ["-c", "%b"]

    with {out, 0} <- System.cmd("stat", flags ++ [path], stderr_to_stdout: true),
         {blocks, ""} <- Integer.parse(String.trim(out)),
         do: {:ok, blocks}
  end

  defp live_dirs(config) do
    root = Config.vms_dir(config)

    for id <- File.ls!(root),
        CrewProtocol.uuid?(id),
        dir = Path.join(root, id),
        not File.exists?(Path.join(dir, "exited.json")),
        do: {id, dir}
  end

  defp disk_gib(dir) do
    with {:ok, data} <- File.read(Path.join(dir, "vm.json")),
         {:ok, %{"size" => %{"disk_gib" => size}}} when is_integer(size) <- Jason.decode(data),
         do: size,
         else: (_ -> 0)
  end
end
