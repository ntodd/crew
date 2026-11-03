defmodule CrewGuest.MixProject do
  use Mix.Project

  @version System.get_env("CREW_VERSION", "0.1.0")

  def project do
    [
      app: :crew_guest,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [mod: {CrewGuest.Application, []}, extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:crew_protocol, path: "../crew_protocol"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:file_system, "~> 1.1"},
      {:bandit, "~> 1.14", only: :test},
      {:plug, "~> 1.20", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # The release baked into the guest image at /opt/crew-guest (§13.5). Its
  # BEAM flags are in rel/vm.args.eex, and its unit is rel/crew-guest.service.
  defp releases do
    [crew_guest: [include_executables_for: [:unix], include_erts: true]]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
