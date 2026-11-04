defmodule CrewCache.MixProject do
  use Mix.Project

  # crew_cache updates with the agent, at the same version (§20.2).
  @version System.get_env("CREW_VERSION", "0.1.0")

  def project do
    [
      app: :crew_cache,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [crew_cache: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      mod: {CrewCache.Application, []},
      extra_applications: [:logger, :crypto, :public_key, :ssl]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:crew_protocol, path: "../crew_protocol"},
      {:bandit, "~> 1.14"},
      {:plug, "~> 1.18"},
      {:finch, "~> 0.24"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.43"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:req, "~> 0.5", only: :test}
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
