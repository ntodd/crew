defmodule Mix.Tasks.CrewImage.Sign do
  @shortdoc "Signs a guest image manifest"
  @moduledoc """
  Signs a guest image manifest's exact bytes (docs/crew_spec.md §13.1),
  writing `<name>.manifest.sig` beside it.

      mix crew_image.sign <manifest.json> [--key-file F | --key-env VAR] [--release]

  With neither key option it signs with the development test key
  (`images/guest/keys/test-signing.key`) and says so. `--release` refuses
  the test key. CI's sign job uses `images/guest/sign.sh` instead, which
  needs only openssl; both make the same signature.
  """
  use Mix.Task

  alias CrewImage.Keys

  @impl true
  def run(args) do
    {opts, [manifest]} =
      OptionParser.parse!(args, strict: [key_file: :string, key_env: :string, release: :boolean])

    release = Keyword.get(opts, :release, false)

    source =
      cond do
        opts[:key_file] -> [file: opts[:key_file]]
        opts[:key_env] -> [env: opts[:key_env]]
        true -> [file: Keys.test_key_path()]
      end

    with {:ok, private} <- Keys.load_private([release: release] ++ source),
         :ok <- CrewImage.Artifacts.sign(manifest, private) do
      public = CrewProtocol.Auth.public_key(private)

      if Keys.test_key?(public),
        do: Mix.shell().info("signed with the TEST KEY (development only)")

      Mix.shell().info(
        "wrote #{CrewImage.Artifacts.signature_path(manifest)} (#{Keys.fingerprint(public)})"
      )
    else
      {:error, reason} -> Mix.raise("crew_image.sign: #{inspect(reason)}")
    end
  end
end
