defmodule Mix.Tasks.CrewImage.Verify do
  @shortdoc "Verifies a guest image release the way a box will"
  @moduledoc """
  Verifies a guest image release (docs/crew_spec.md §13.1): the signature
  over the manifest's exact bytes, the manifest's fields, the kernel and
  compressed rootfs against it, and the 2 GiB limit.

      mix crew_image.verify <manifest.json> [--public-key B64 | --public-key-file F]
                            [--rootfs-ext4 P] [--release]

  The public key defaults to the development test key's. `--release`
  refuses the test key. `--rootfs-ext4` also checks an uncompressed
  rootfs.
  """
  use Mix.Task

  alias CrewImage.{Artifacts, Keys}

  @impl true
  def run(args) do
    {opts, [manifest]} =
      OptionParser.parse!(args,
        strict: [
          public_key: :string,
          public_key_file: :string,
          rootfs_ext4: :string,
          release: :boolean
        ]
      )

    public =
      case {opts[:public_key], opts[:public_key_file]} do
        {nil, nil} -> {:ok, Keys.test_public_key()}
        {nil, file} -> Keys.load_public(file: file)
        {value, _} -> Keys.load_public(value: value)
      end

    with {:ok, public} <- public,
         :ok <-
           Artifacts.verify(manifest, public,
             release: Keyword.get(opts, :release, false),
             rootfs_ext4: opts[:rootfs_ext4]
           ) do
      key = if Keys.test_key?(public), do: "the TEST KEY", else: Keys.fingerprint(public)
      Mix.shell().info("ok: #{Path.basename(manifest)}, signed by #{key}")
    else
      {:error, problems} -> Mix.raise("crew_image.verify: #{inspect(problems)}")
    end
  end
end
