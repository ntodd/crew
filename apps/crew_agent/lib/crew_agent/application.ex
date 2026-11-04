defmodule CrewAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    config = CrewAgent.Config.load()
    CrewAgent.Config.put(config)
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
        CrewAgent.VMs,
        CrewAgent.Ops,
        %{
          id: :adopt,
          start: {Task, :start_link, [&CrewAgent.VMs.adopt_all/0]},
          restart: :temporary
        }
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

  defp null_supervisor(%{driver: "null"}),
    do: {DynamicSupervisor, name: CrewAgent.Driver.Null.Supervisor, strategy: :one_for_one}

  defp null_supervisor(_), do: nil
end
