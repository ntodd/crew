defmodule CrewAgent.Config do
  @moduledoc """
  Agent configuration (§21.2), read once at boot from the application
  environment, which `config/runtime.exs` fills from `CREW_*` variables
  (`${CREW_DATA_DIR}/agent/env` on a box).

  All agent state lives under `data_dir` (§10.1): `agent/identity.json`,
  `vms/<vm_id>/`, `images/<image_id>/`.
  """

  defstruct url: nil,
            join_token: nil,
            box_name: nil,
            driver: "null",
            data_dir: "/srv/crew",
            service_ip: "10.199.0.1",
            vm_net: "10.200.0.0/16",
            uplink: nil,
            extra_blocked: [],
            guest_api_ip: nil,
            guest_api_port: 7777,
            vzd_socket: nil,
            vz_host_reserve_vcpus: 2,
            vz_host_reserve_mib: 8192,
            vz_vm_area_gib: 400,
            cache_mgmt_url: nil,
            cache_mgmt_token: nil,
            release_public_key: nil,
            null_guest_cmd: nil,
            dev: false,
            connect: true,
            proc: "/proc"

  @type t :: %__MODULE__{}

  @spec load() :: t()
  def load do
    env = Application.get_all_env(:crew_agent)

    __MODULE__
    |> struct(Keyword.take(env, Map.keys(%__MODULE__{}) -- [:__struct__]))
    |> Map.update!(:box_name, &(&1 || hostname()))
    |> Map.update!(:release_public_key, &decode_key/1)
  end

  @doc "The loaded config. Loaded on first use and cached."
  @spec get() :: t()
  def get do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        config = load()
        :persistent_term.put(__MODULE__, config)
        config

      config ->
        config
    end
  end

  def put(%__MODULE__{} = config), do: :persistent_term.put(__MODULE__, config)

  @doc """
  Checks the control plane URL: `wss://` only, unless `CREW_DEV=1`
  allows `ws://` (§5.3).
  """
  @spec check_url(t()) :: :ok | {:error, String.t()}
  def check_url(%__MODULE__{url: url, dev: dev}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host} when is_binary(host) -> :ok
      %URI{scheme: "ws", host: host} when is_binary(host) and dev -> :ok
      %URI{scheme: "ws"} -> {:error, "CREW_URL must be wss:// (ws:// only with CREW_DEV=1)"}
      _ -> {:error, "CREW_URL must be a wss:// URL"}
    end
  end

  def check_url(_config), do: {:error, "CREW_URL isn't set"}

  def agent_dir(%__MODULE__{data_dir: d}), do: Path.join(d, "agent")
  def vms_dir(%__MODULE__{data_dir: d}), do: Path.join(d, "vms")
  def images_dir(%__MODULE__{data_dir: d}), do: Path.join(d, "images")
  def vm_dir(config, vm_id), do: Path.join(vms_dir(config), vm_id)

  @doc "The driver module for the configured driver."
  def driver_module(%__MODULE__{driver: "vz"}), do: CrewAgent.Driver.VZ
  def driver_module(%__MODULE__{driver: "firecracker"}), do: CrewAgent.Driver.Firecracker

  def driver_module(%__MODULE__{driver: "null"}) do
    # Compiled only in dev and test (§11.5); a release refuses it.
    if Code.ensure_loaded?(CrewAgent.Driver.Null),
      do: CrewAgent.Driver.Null,
      else: raise("the null driver isn't in this build (it's for development only)")
  end

  def hostname do
    {:ok, name} = :inet.gethostname()
    name |> to_string() |> String.downcase() |> String.split(".") |> hd()
  end

  defp decode_key(nil), do: nil
  defp decode_key(""), do: nil
  defp decode_key(key) when byte_size(key) == 32, do: key
  defp decode_key(key) when is_binary(key), do: Base.decode64!(String.trim(key))
end
