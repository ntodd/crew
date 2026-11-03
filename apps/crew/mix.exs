defmodule Crew.MixProject do
  use Mix.Project

  # CI sets the version for tagged builds, the same as the agents built
  # with it.
  @version System.get_env("CREW_VERSION", "0.1.0")

  def project do
    [
      app: :crew,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: [crew: [include_executables_for: [:unix]]],
      # Advisories `mix hex.audit` reports that don't reach this app. Each
      # needs its reason here; drop it once a fixed release is locked.
      hex: [
        ignore_advisories: [
          # No fix released. The AES-CTR cipher is unauthenticated; the
          # vault uses only Cloak.Ciphers.AES.GCM (Crew.Vault).
          "EEF-CVE-2026-95105",
          # No fix released. Affects Cloak.Ecto.PBKDF2 fields, which no
          # schema uses.
          "EEF-CVE-2026-94206"
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Crew.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :public_key]
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
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      # Both adapters are always available; CREW_DB picks one at
      # compile time (see config/config.exs).
      {:ecto_sqlite3, "~> 0.25"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.14"},
      {:req, "~> 0.5"},
      {:oban, "~> 2.24"},
      {:oban_web, "~> 2.13"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:hammer, "~> 7.5"},
      {:boundary, "~> 0.11.0", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16.0", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.3", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  # Recent macOS releases kill the downloaded ad-hoc-signed Tailwind and
  # esbuild binaries (exit 137). Re-signing them locally fixes it.
  defp resign_macos_binaries(_args) do
    if match?({:unix, :darwin}, :os.type()) do
      for bin <- Path.wildcard("_build/{tailwind,esbuild}-*") do
        System.cmd("codesign", ["--force", "--sign", "-", bin], stderr_to_stdout: true)
      end
    end

    :ok
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        &resign_macos_binaries/1
      ],
      "assets.build": ["compile", "tailwind crew", "esbuild crew"],
      "assets.deploy": [
        "tailwind crew --minify",
        "esbuild crew --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "sobelow --config --exit",
        "test"
      ]
    ]
  end
end
