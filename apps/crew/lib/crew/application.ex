defmodule Crew.Application do
  @moduledoc false
  use Boundary, top_level?: true, deps: [Crew, CrewWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CrewWeb.Telemetry,
      Crew.Vault,
      Crew.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:crew, :ecto_repos), skip: skip_migrations?()},
      %{
        id: :check_encryption_key,
        start: {Crew.Settings, :start_checking_encryption_key, []},
        restart: :temporary
      },
      {Phoenix.PubSub, name: Crew.PubSub},
      {Registry, keys: :unique, name: Crew.Registry},
      {Crew.RateLimit, clean_period: :timer.minutes(1)},
      {Oban, Application.fetch_env!(:crew, Oban)},
      Crew.Setup,
      CrewWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Crew.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CrewWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Releases migrate on boot; in dev and test, mix does it.
  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
