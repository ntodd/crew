defmodule CrewAgent.GuestAPI.Socket do
  @moduledoc "One VM's guest API listener on its Unix socket (vz, §13.4)."
  use GenServer, restart: :transient

  def start_link({vm_id, path}),
    do:
      GenServer.start_link(__MODULE__, {vm_id, path},
        name: {:via, Registry, {CrewAgent.Registry, {:guest_socket, vm_id}}}
      )

  @impl true
  def init({vm_id, path}) do
    Process.flag(:trap_exit, true)
    CrewAgent.GuestAPI.init_tables()
    File.rm(path)

    {:ok, bandit} =
      Bandit.start_link(
        plug: {CrewAgent.GuestAPI, vm_id: vm_id},
        scheme: :http,
        ip: {:local, path},
        port: 0,
        startup_log: false,
        thousand_island_options: [read_timeout: 10_000, num_acceptors: 2]
      )

    File.chmod(path, 0o660)
    {:ok, %{bandit: bandit, path: path}}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{bandit: pid} = state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.bandit), do: Supervisor.stop(state.bandit)
    File.rm(state.path)
    :ok
  end
end
