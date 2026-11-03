defmodule CrewGuest.Application do
  @moduledoc false

  use Application

  alias CrewGuest.{Config, Session}

  @impl true
  def start(_type, _args) do
    children = [finch() | session(Application.get_env(:crew_guest, :autostart, true))]
    Supervisor.start_link(children, strategy: :one_for_one, name: CrewGuest.Supervisor)
  end

  # The guest API allows 4 connections per VM (§13.4): the control poll,
  # the outbox's two lanes and metrics. Idle connections are dropped before
  # the agent's 10 s read timeout would close them under us.
  defp finch do
    {Finch,
     name: CrewGuest.Finch,
     pools: %{
       default: [
         size: 4,
         count: 1,
         conn_max_idle_time: 5_000,
         conn_opts: [transport_opts: [timeout: 2_000]]
       ]
     }}
  end

  defp session(false), do: []

  defp session(true) do
    case Config.load() do
      {:ok, cfg} ->
        [{Session, config: cfg, system: CrewGuest.System.impl(cfg.mode)}]

      {:error, reason} ->
        [Supervisor.child_spec({Task, fn -> Session.fail(reason) end}, restart: :temporary)]
    end
  end
end
