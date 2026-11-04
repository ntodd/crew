defmodule CrewCache.Application do
  @moduledoc false
  use Application

  # A release starts the cache (config sets `autostart`); tests, and
  # apps that depend on crew_cache, start `{CrewCache, opts}` themselves.
  @impl true
  def start(_type, _args) do
    children = if Application.get_env(:crew_cache, :autostart, false), do: [CrewCache], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: CrewCache.AppSupervisor)
  end
end
