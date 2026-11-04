defmodule CrewCache.DNS do
  @moduledoc """
  The guests' resolver (§15.2 item 1), UDP and TCP on the listen
  address, port 53. Design A, so it intercepts nothing: it forwards to
  `CREW_DNS_UPSTREAMS` (never the host's resolver) and polices what goes
  through (`CrewCache.DNS.Query`).
  """
  use Supervisor

  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @doc "The port the resolver listens on (UDP and TCP)."
  def port, do: :persistent_term.get({__MODULE__, :port})

  @impl true
  def init(config) do
    Supervisor.init(
      [
        CrewCache.DNS.Cache,
        {Task.Supervisor, name: CrewCache.DNS.Tasks, max_children: 2048},
        {Task.Supervisor, name: CrewCache.DNS.TCPTasks, max_children: 256},
        {CrewCache.DNS.Server, config}
      ],
      strategy: :rest_for_one
    )
  end
end
