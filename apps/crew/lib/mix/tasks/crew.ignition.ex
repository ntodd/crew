defmodule Mix.Tasks.Crew.Ignition do
  @shortdoc "Renders a sample Flatcar box Ignition"

  @moduledoc """
  Renders the Ignition a Flatcar box gets (`Crew.Boxes.Flatcar`) with
  placeholder values: no join token, release or key that works. CI runs
  `ignition-validate` on one for every box type, arch and mode; it's
  also a quick look at what a box gets.

      mix crew.ignition --type linux-vm --arch amd64 [--reprovision] [--out box.ign]
      mix crew.ignition --type cachevm [--reprovision]    # a mac-vz box's cache VM (arm64)

  A box that boots needs a real one: `POST /agent/flatcar/ignition`
  with a join token from Add box.
  """
  use Boundary, classify_to: Crew
  use Mix.Task

  alias Crew.Boxes.Flatcar

  @switches [type: :string, arch: :string, reprovision: :boolean, out: :string]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    type = opts[:type] || "linux-vm"
    arch = opts[:arch] || "amd64"
    mode = if opts[:reprovision], do: :reprovision, else: :provision

    rendered =
      if type == "cachevm",
        do: Flatcar.cachevm_ignition(cachevm_sample(mode)),
        else: Flatcar.ignition(sample(type, arch, mode))

    case rendered do
      {:ok, config} ->
        json = Jason.encode!(config, pretty: true)
        if out = opts[:out], do: File.write!(out, json <> "\n"), else: Mix.shell().info(json)

      {:error, reason} ->
        Mix.raise("couldn't render the Ignition: #{reason}")
    end
  end

  defp cachevm_sample(mode) do
    %{
      mode: mode,
      arch: "arm64",
      ssh_keys: [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNyZXctc2FtcGxlLWtleS0wMDAwMDAwMDAwMDA sample"
      ],
      mgmt_token: if(mode == :provision, do: "cm_" <> String.duplicate("s", 43)),
      release:
        if(mode == :provision,
          do: %{
            version: "0.0.0",
            cache: %{
              url:
                "https://github.com/ntodd/crew/releases/download/v0.0.0/crew-cache-0.0.0-linux-arm64.tar.gz",
              sha256: String.duplicate("0", 64),
              signature: Base.encode64(:binary.copy(<<0>>, 64))
            }
          }
        ),
      release_key: :binary.copy(<<1>>, 32)
    }
  end

  defp sample(type, arch, mode) do
    target = Flatcar.target(arch)
    base = "https://github.com/ntodd/crew/releases/download/v0.0.0"

    artifact = fn component ->
      %{
        url: "#{base}/crew-#{component}-0.0.0-#{target}.tar.gz",
        sha256: String.duplicate("0", 64),
        signature: Base.encode64(:binary.copy(<<0>>, 64))
      }
    end

    %{
      mode: mode,
      name: "sample",
      type: type,
      arch: arch,
      data_disk: if(type == "linux-metal", do: "/dev/sdb"),
      ssh_keys: [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNyZXctc2FtcGxlLWtleS0wMDAwMDAwMDAwMDA sample"
      ],
      url: if(mode == :provision, do: "https://crew.example.ts.net"),
      join_token: if(mode == :provision, do: "cj_sample"),
      tailscale_auth_key: if(mode == :provision, do: "tskey-auth-sample"),
      release:
        if(mode == :provision,
          do: %{version: "0.0.0", agent: artifact.("agent"), cache: artifact.("cache")}
        ),
      release_key: :binary.copy(<<1>>, 32),
      dev: false
    }
  end
end
