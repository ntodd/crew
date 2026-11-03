defmodule CrewAgent.MixProject do
  use Mix.Project

  # CI sets the version for tagged builds; self-update compares it.
  @version System.get_env("CREW_VERSION", "0.1.0")

  def project do
    [
      app: :crew_agent,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [crew_agent: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      mod: {CrewAgent.Application, []},
      extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # The null driver (§11.5) is compiled only for dev and test.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:crew_protocol, path: "../crew_protocol"},
      {:slipstream, "~> 1.2"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:muontrap, "~> 2.0"},
      {:bandit, "~> 1.14"},
      {:plug, "~> 1.18"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.3", only: :test},
      {:phoenix, "~> 1.8", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
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
