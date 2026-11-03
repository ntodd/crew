defmodule CrewAgent.Net do
  @moduledoc """
  Network leases (§14.1): one /30 per VM out of `CREW_VM_NET`
  (10.200.0.0/16 by default, so 16,384 leases), `.1` the gateway on the
  host side and `.2` the guest. Lease `n` is the n-th /30; 0 is never
  used. Leases are kept in `vm.json`, so adoption re-claims them.

  On Firecracker boxes a lease also means a tap and an `@vm_pairs` entry,
  through crew-vmctl (§10.8); the driver does that part.
  """
  use GenServer

  import Bitwise

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "A free lease for `vm_id` (the same one if it already has one)."
  def allocate(vm_id), do: GenServer.call(__MODULE__, {:allocate, vm_id})

  @doc "Re-claims a lease an adopted VM already holds."
  def claim(vm_id, index), do: GenServer.call(__MODULE__, {:claim, vm_id, index})

  def release(vm_id), do: GenServer.call(__MODULE__, {:release, vm_id})

  @doc "The addresses of lease `index` in `cidr`."
  def lease(index, cidr \\ CrewAgent.Config.get().vm_net) do
    {base, bits} = parse_cidr(cidr)
    network = base + index * 4
    true = index >= 1 and index < capacity(bits)

    %{
      index: index,
      network: ntoa(network),
      gateway: ntoa(network + 1),
      guest: ntoa(network + 2),
      netmask: "255.255.255.252",
      mac: mac(network + 2)
    }
  end

  def capacity(bits), do: 1 <<< (32 - bits - 2)

  defp mac(ip) do
    <<a, b, c, d>> = <<ip::32>>

    Enum.map_join(
      [0x02, 0xC2, a, b, c, d],
      ":",
      &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
    )
  end

  def parse_cidr(cidr) do
    [addr, bits] = String.split(cidr, "/")
    {:ok, {a, b, c, d}} = :inet.parse_ipv4strict_address(String.to_charlist(addr))
    bits = String.to_integer(bits)
    mask = bnot((1 <<< (32 - bits)) - 1) &&& 0xFFFFFFFF
    {(a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d) &&& mask, bits}
  end

  defp ntoa(n), do: n |> then(&<<&1::32>>) |> then(fn <<a, b, c, d>> -> "#{a}.#{b}.#{c}.#{d}" end)

  @impl true
  def init(opts) do
    cidr = Keyword.get_lazy(opts, :cidr, fn -> CrewAgent.Config.get().vm_net end)
    {_base, bits} = parse_cidr(cidr)
    {:ok, %{cidr: cidr, capacity: capacity(bits), by_vm: %{}, used: MapSet.new()}}
  end

  @impl true
  def handle_call({:allocate, vm_id}, _from, state) do
    case Map.fetch(state.by_vm, vm_id) do
      {:ok, index} ->
        {:reply, {:ok, lease(index, state.cidr)}, state}

      :error ->
        case Enum.find(1..(state.capacity - 1), &(not MapSet.member?(state.used, &1))) do
          nil -> {:reply, {:error, :no_leases}, state}
          index -> {:reply, {:ok, lease(index, state.cidr)}, take(state, vm_id, index)}
        end
    end
  end

  def handle_call({:claim, vm_id, index}, _from, state) do
    cond do
      Map.get(state.by_vm, vm_id) == index -> {:reply, {:ok, lease(index, state.cidr)}, state}
      MapSet.member?(state.used, index) -> {:reply, {:error, :taken}, state}
      true -> {:reply, {:ok, lease(index, state.cidr)}, take(state, vm_id, index)}
    end
  end

  def handle_call({:release, vm_id}, _from, state) do
    case Map.pop(state.by_vm, vm_id) do
      {nil, _} ->
        {:reply, :ok, state}

      {index, by_vm} ->
        {:reply, :ok, %{state | by_vm: by_vm, used: MapSet.delete(state.used, index)}}
    end
  end

  defp take(state, vm_id, index),
    do: %{state | by_vm: Map.put(state.by_vm, vm_id, index), used: MapSet.put(state.used, index)}
end
