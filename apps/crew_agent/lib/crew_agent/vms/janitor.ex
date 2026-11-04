defmodule CrewAgent.VMs.Janitor do
  @moduledoc """
  What runs at agent start, before the VMs are the control plane's to
  command (§10.7), and after:

  1. adoption (`CrewAgent.VMs.adopt_all/0`);
  2. the leases of VMs whose cleanup is pending, taken back;
  3. those cleanups, tried again;
  4. what the driver holds for VMs the agent has no record of, cleaned
     up (`CrewAgent.VMs.Cleanup.reconcile/0`);

  then pending cleanups again every minute.
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
  def init(opts),
    do: {:ok, %{every: Keyword.get(opts, :every_ms, @every_ms)}, {:continue, :start}}

  @impl true
  def handle_continue(:start, state) do
    VMs.adopt_all()
    Cleanup.claim_leases()
    Cleanup.retry_all()
    Cleanup.reconcile()
    Process.send_after(self(), :retry, state.every)
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry, state) do
    Cleanup.retry_all()
    Process.send_after(self(), :retry, state.every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
