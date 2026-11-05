defmodule CrewAgent.CacheVM do
  @moduledoc """
  A `mac-vz` box's cache VM (§12.1, §12.3, §15.6), from the agent on
  the Mac. The cache VM is a Flatcar VM the mac-vm launcher runs with
  `--role cache` (install-macos.sh `--cache-vm`); it runs crew_cache,
  and nothing of the agent's.

  - **Its address** is its newest lease in vmnet's DHCP leases
    (`/var/db/dhcpd_leases`), by its MAC (`CREW_VZ_CACHE_MAC`), read
    each time it's needed; `CREW_VZ_CACHE_ADDR` overrides it. crew-vz
    forwards each job VM's `10.199.0.1:{53,80,443}` there.
  - **Management** is on that address, port 7780, with
    `CREW_CACHE_MGMT_TOKEN` (the cache VM DNATs it to crew_cache, and
    only for the Mac).
  - **Its reboot state** is crew_cache's `GET /host`, sent as
    `box.reboot`'s `cache_vm`.
  - **`cachevm.restart`** writes `run/restart-cachevm` under the data
    directory, which root's `com.crew.hostvm-restart` LaunchDaemon
    watches: it restarts the VM (`crew-box restart --role cache`), and
    the control plane sees the new boot ID in the next `box.reboot`.
  """

  alias CrewAgent.{Cache, Config}

  @doc "The cache VM's IPv4 address, or nil when there's none to be found."
  @spec address(Config.t()) :: String.t() | nil
  def address(%Config{vz_cache: %{addr: addr}}) when is_binary(addr) and addr != "",
    do: ipv4(addr)

  def address(%Config{vz_cache: %{mac: mac, leases: leases}}) when is_binary(mac) and mac != "" do
    case File.read(leases) do
      {:ok, text} -> text |> lease(mac) |> ipv4()
      {:error, _} -> nil
    end
  end

  def address(_config), do: nil

  @doc """
  The newest lease's address for `mac` in a vmnet `dhcpd_leases` file:
  bootpd drops the octets' leading zeros (`52:54:0:a:b:c`) and keeps
  each lease's expiry in hex.
  """
  @spec lease(String.t(), String.t()) :: String.t() | nil
  def lease(text, mac) do
    hw = "1," <> short_mac(mac)

    text
    |> String.split("}")
    |> Enum.map(&fields/1)
    |> Enum.filter(&(&1["hw_address"] == hw))
    |> Enum.max_by(&expiry(&1["lease"]), fn -> %{} end)
    |> Map.get("ip_address")
  end

  defp short_mac(mac) do
    mac
    |> String.downcase()
    |> String.split(":")
    |> Enum.map_join(":", &String.replace(&1, ~r/^0(?=.)/, ""))
  end

  defp fields(block) do
    for line <- String.split(block, "\n"),
        [key, value] <- [String.split(String.trim(line), "=", parts: 2)],
        into: %{},
        do: {key, value}
  end

  defp expiry("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp expiry(_), do: 0

  defp ipv4(text) when is_binary(text) do
    case :inet.parse_ipv4strict_address(String.to_charlist(text)) do
      {:ok, _} -> text
      _ -> nil
    end
  end

  defp ipv4(_), do: nil

  @doc "The cache's management URL: `CREW_CACHE_MGMT_URL`, else the cache VM's, else nil."
  @spec mgmt_url(Config.t()) :: String.t() | nil
  def mgmt_url(%Config{cache_mgmt_url: url}) when is_binary(url) and url != "", do: url

  def mgmt_url(%Config{} = config) do
    if addr = address(config), do: "http://#{addr}:#{config.vz_cache.mgmt_port}"
  end

  @doc "Whether this box has a cache VM (a `mac-vz` box that names one)."
  def configured?(%Config{driver: "vz"} = config),
    do: present?(config.vz_cache.mac) or present?(config.vz_cache.addr)

  def configured?(_config), do: false

  defp present?(value), do: is_binary(value) and value != ""

  @doc "Whether job VMs can be given the cache VM: none is configured, or its cache answers."
  def ready?(%Config{} = config),
    do: not configured?(config) or match?({:ok, _}, Cache.host(config))

  @doc "The cache VM's reboot state for `box.reboot`'s `cache_vm`, or nil."
  @spec reboot(Config.t()) :: map() | nil
  def reboot(%Config{} = config) do
    with true <- configured?(config),
         {:ok, %{"boot_id" => boot_id} = host} when is_binary(boot_id) <- Cache.host(config) do
      %{
        required: host["reboot_required"] == true,
        packages: host |> Map.get("packages", []) |> List.wrap() |> Enum.take(50),
        boot_id: boot_id
      }
    else
      _ -> nil
    end
  end

  @doc """
  `cachevm.restart` (§12.1): on the boot the control plane saw, asks
  launchd to restart the cache VM; on another, it already has.
  """
  def restart(%Config{} = config, boot_id) do
    case reboot(config) do
      nil ->
        {:error, "cachevm_unreachable", "the cache VM didn't answer GET /host"}

      %{boot_id: ^boot_id} ->
        dir = Path.join(config.data_dir, "run")
        File.mkdir_p!(dir)
        CrewAgent.SafeFS.write_atomic(Path.join(dir, "restart-cachevm"), boot_id <> "\n", 0o644)

      %{} ->
        {:ok, %{"already" => true}}
    end
  end
end
