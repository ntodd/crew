defmodule CrewImage.MixProject do
  use Mix.Project

  # The guest image's tools (docs/crew_spec.md §13.1): the manifest, its
  # signature and their check, and the smoke boot. Signing goes through
  # CrewProtocol.Auth, the same code the control plane and the agent
  # verify with.
  def project do
    [
      app: :crew_image,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: false,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  def cli, do: [preferred_envs: [precommit: :test]]

  defp deps do
    [
      {:crew_protocol, path: "../../../apps/crew_protocol"},
      {:jason, "~> 1.4"},
      # The smoke boot's fake guest API, on the VM's guest.sock.
      {:bandit, "~> 1.14"},
      {:plug, "~> 1.20"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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
