defmodule Crew.Application do
  @moduledoc false
  use Boundary, top_level?: true, deps: [Crew, CrewWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
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
        Crew.Cache,
        {Crew.RateLimit, clean_period: :timer.minutes(1)},
        Crew.Agents.NonceCache,
        Crew.GitHub.Budget,
        Crew.GitHub.InstallationTokens,
        {Oban, Application.fetch_env!(:crew, Oban)},
        Crew.VMs,
        Crew.Logs,
        Crew.Setup,
        CrewWeb.Endpoint
      ] ++ background()

    Supervisor.start_link(children, strategy: :one_for_one, name: Crew.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CrewWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # GitHub's listener (§6.2) and the reconciler's ticker. Tests drive
  # both directly.
  defp background do
    if Application.get_env(:crew, :env) == :test do
      []
    else
      [
        {Bandit,
         plug: CrewWeb.HookEndpoint,
         scheme: :http,
         ip: Application.get_env(:crew, :hook_ip, {127, 0, 0, 1}),
         port: Application.get_env(:crew, :hook_port, 4001),
         thousand_island_options: [num_acceptors: 10]},
        Crew.Reconciler.Ticker,
        Crew.Jobs.Watcher,
        %{id: :boot_vms, start: {Task, :start_link, [&boot_vms/0]}, restart: :temporary},
        Crew.Scheduler
      ]
    end
  end

  # A server for every VM that isn't destroyed (§8.6); the guest images
  # and agent tarballs this release carries (§20.1); and in development
  # the null driver's placeholder images.
  defp boot_vms do
    if dir = present(Application.get_env(:crew, :image_release_dir)),
      do: Crew.Images.register_bundle(dir)

    # The image's agent tarballs, copied onto the data volume, and the
    # copies kept there for boxes pinned to older versions (§20.2).
    Crew.Agents.Releases.register_at_boot(present(Application.get_env(:crew, :agent_release_dir)))

    Crew.Images.check_mirrors()
    # The runner's freshness (§13.1) is checked daily; a new deployment
    # checks at once rather than show nothing for a day.
    if Crew.Images.Runner.releases() == [], do: Oban.insert(Crew.Images.Runner.new(%{}))
    # Crew's own releases (§20.3), likewise.
    if Crew.Updates.enabled?() and is_nil(Crew.Updates.latest()),
      do: Oban.insert(Crew.Updates.Check.new(%{}))

    # The placeholders stand in only when there's no release to register.
    if Crew.Config.dev?() and is_nil(Application.get_env(:crew, :image_release_dir)),
      do: Crew.Images.register_dev_images()

    Crew.VMs.boot_servers()
  end

  # An env file can set a directory to "".
  defp present(dir) when is_binary(dir) and dir != "", do: dir
  defp present(_), do: nil

  # Releases migrate on boot; in dev and test, mix does it.
  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
