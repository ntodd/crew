defmodule CrewAgent.VMs.Janitor do
  @moduledoc """
  What runs at agent start, before the VMs are the control plane's to
  command (§10.7), and after:

  1. in `init`, so before the link starts: every lease the agent's
     records hold (live VMs, pending cleanups) taken back; a lease two
     records hold blocks starts (`CrewAgent.VMs.Cleanup.reserve_leases/0`);
  2. adoption (`CrewAgent.VMs.adopt_all/0`);
  3. pending cleanups, tried again;
  4. what the driver holds for VMs the agent has no record of, cleaned
     up, their leases held until it works
     (`CrewAgent.VMs.Cleanup.reconcile/0`);

  then 1, 3 and 4 again every minute.
  """
  use GenServer

  alias CrewAgent.VMs
  alias CrewAgent.VMs.Cleanup

  @every_ms 60_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  # Every lease the agent's records hold, taken here, synchronously: the
  # application starts the link (and so any vm.start) only after this
  # returns. Adoption and the rest can wait for handle_continue.
  def init(opts) do
    Cleanup.reserve_leases()
    {:ok, %{every: Keyword.get(opts, :every_ms, @every_ms)}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    VMs.adopt_all()
    Cleanup.retry_all()
    Cleanup.reconcile()
    Process.send_after(self(), :retry, state.every)
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry, state) do
    Cleanup.reserve_leases()
    Cleanup.retry_all()
    Cleanup.reconcile()
    Process.send_after(self(), :retry, state.every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
