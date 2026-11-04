defmodule CrewCache do
  @moduledoc """
  Crew's per-box registry cache and guest DNS resolver (§15).

  In a release the application starts it from the environment
  (`config/runtime.exs`). Elsewhere, start it under a supervisor with
  options that override the environment (see `CrewCache.Config`):

      start_supervised!(
        {CrewCache,
         dir: tmp_dir,
         listen: {127, 0, 0, 1},
         https_port: 0,
         http_port: 0,
         dns_port: 0,
         mgmt: {{127, 0, 0, 1}, 0}}
      )

      %{https: _, http: _, dns: _, mgmt: mgmt} = CrewCache.ports()

  One cache runs per node: its processes are named.
  """

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {CrewCache.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts), do: CrewCache.Supervisor.start_link(opts)

  @doc "The ports the running cache's listeners got (those that are configured)."
  def ports do
    listeners =
      for {id, pid, _, _} <- Supervisor.which_children(CrewCache.Supervisor),
          id in [:registry_https, :registry_http, :mgmt],
          is_pid(pid),
          {:ok, {_ip, port}} = ThousandIsland.listener_info(pid),
          into: %{},
          do: {Map.fetch!(%{registry_https: :https, registry_http: :http, mgmt: :mgmt}, id), port}

    case Process.whereis(CrewCache.DNS) do
      nil -> listeners
      _ -> Map.put(listeners, :dns, CrewCache.DNS.port())
    end
  end
end
