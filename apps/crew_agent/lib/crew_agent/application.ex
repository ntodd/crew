defmodule CrewAgent.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    config = CrewAgent.Config.load()
    CrewAgent.Config.put(config)
    rollback_if_due(config)

    if config.conformance,
      do:
        Logger.warning(
          "CREW_CONFORMANCE=1: every VM runs the guest image's conformance checks instead of its job (§11.6)"
        )

    File.mkdir_p!(CrewAgent.Config.vms_dir(config))
    File.mkdir_p!(CrewAgent.Config.images_dir(config))

    # The link to the control plane sits apart from what runs VMs: a
    # socket fault that keeps restarting exhausts the link's supervisor,
    # never the one holding the VMs' servers.
    link = %{
      id: CrewAgent.LinkSupervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [CrewAgent.Reporter, CrewAgent.Connection],
           [
             strategy: :one_for_one,
             max_restarts: 10,
             max_seconds: 60,
             name: CrewAgent.LinkSupervisor
           ]
         ]}
    }

    children =
      [
        {Registry, keys: :unique, name: CrewAgent.Registry},
        CrewAgent.Outbox,
        CrewAgent.Net,
        CrewAgent.Site,
        CrewAgent.GuestAPI,
        {DynamicSupervisor, name: CrewAgent.GuestAPI.Sockets, strategy: :one_for_one},
        null_supervisor(config),
        if(config.driver == "firecracker", do: CrewAgent.Driver.Firecracker.Monitor),
        CrewAgent.VMs,
        CrewAgent.Ops,
        # A Mac's cache is its cache VM's, without CREW_CACHE_MGMT_URL.
        if(CrewAgent.Cache.present?(config), do: CrewAgent.Cache.Stats),
        # crew-vzd onto the release an update installed, once idle (§20.2).
        if(config.driver == "vz", do: CrewAgent.Driver.VZ.Upgrade),
        # Adoption, then cleanups left pending or never recorded (§10.7).
        CrewAgent.VMs.Janitor
      ]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(if config.connect, do: [link], else: [])

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 60,
      name: CrewAgent.Supervisor
    )
  end

  # Before anything stops (an update, a service restart): the VMs' log
  # lines that only this agent holds go to the control plane, which acks
  # them within a second or so (§16.2, §11.6 item 9).
  @impl true
  def prep_stop(state) do
    case CrewAgent.VMs.drain_logs(3_000) do
      :ok -> :ok
      :timeout -> Logger.warning("stopping with VM log lines the control plane hasn't acked")
    end

    state
  catch
    :exit, _ -> state
  end

  # An update that hasn't joined within 5 minutes of its first start on
  # this boot goes back now, however often it has restarted since
  # (§20.2): before anything starts, so there's nothing to stop.
  defp rollback_if_due(config) do
    case CrewAgent.Updater.on_start(config) do
      :ok ->
        :ok

      {:stop, status} ->
        IO.puts(
          :stderr,
          "crew_agent: rolling back an update that hasn't joined; exiting #{status}"
        )

        System.halt(status)
    end
  end

  defp null_supervisor(%{driver: "null"}),
    do: {DynamicSupervisor, name: CrewAgent.Driver.Null.Supervisor, strategy: :one_for_one}

  defp null_supervisor(_), do: nil
end
