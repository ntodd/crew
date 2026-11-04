defmodule Mix.Tasks.Crew.Sign do
  @shortdoc "Signs a release's agent and cache tarballs"
  @moduledoc """
  Signs every `crew-<agent|cache>-<version>-<target>.tar.gz` in a
  directory (spec §20.1 item 6), writing `.sha256` and `.sig` beside each.

      mix crew.sign <dir> [--key-file F | --key-env VAR] [--release]

  With neither key option it signs with the development test key and says
  so. `--release` refuses the test key, as `crew_image.sign` does.
  """
  use Mix.Task

  alias CrewImage.{Keys, Release}

  @impl true
  def run(args) do
    {opts, [dir]} =
      OptionParser.parse!(args, strict: [key_file: :string, key_env: :string, release: :boolean])

    source =
      cond do
        opts[:key_file] -> [file: opts[:key_file]]
        opts[:key_env] -> [env: opts[:key_env]]
        true -> [file: Keys.test_key_path()]
      end

    with {:ok, private} <-
           Keys.load_private([release: Keyword.get(opts, :release, false)] ++ source),
         {:ok, signed} <- Release.sign_dir(dir, private) do
      public = CrewProtocol.Auth.public_key(private)

      if Keys.test_key?(public),
        do: Mix.shell().info("signed with the TEST KEY (development only)")

      for f <- signed, do: Mix.shell().info("signed #{f} (#{Keys.fingerprint(public)})")
    else
      {:error, reason} -> Mix.raise("crew.sign: #{inspect(reason)}")
    end
  end
end
