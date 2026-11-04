defmodule Mix.Tasks.Crew.Verify do
  @shortdoc "Verifies a release's agent and cache tarballs"
  @moduledoc """
  Checks every `crew-<agent|cache>-<version>-<target>.tar.gz` in a
  directory the way the control plane registers it and a box installs
  it (spec §20.1, §20.2): it matches its `.sha256`, and its `.sig`
  verifies over version, target and SHA-256, with
  `CrewProtocol.Auth.verify_release/5`.

      mix crew.verify <dir> [--public-key B64 | --public-key-file F] [--release]

  The public key defaults to the development test key's. `--release`
  refuses the test key, as `crew_image.verify` does.
  """
  use Mix.Task

  alias CrewImage.{Keys, Release}

  @impl true
  def run(args) do
    {opts, [dir]} =
      OptionParser.parse!(args,
        strict: [public_key: :string, public_key_file: :string, release: :boolean]
      )

    public =
      case {opts[:public_key], opts[:public_key_file]} do
        {nil, nil} -> {:ok, Keys.test_public_key()}
        {nil, file} -> Keys.load_public(file: file)
        {value, _} -> Keys.load_public(value: value)
      end

    with {:ok, public} <- public,
         :ok <- refuse_test_key(public, opts[:release]),
         {:ok, files} <- Release.verify_dir(dir, public) do
      key = if Keys.test_key?(public), do: "the TEST KEY", else: Keys.fingerprint(public)
      for f <- files, do: Mix.shell().info("ok: #{f}, signed by #{key}")
    else
      {:error, :test_key_for_release} ->
        Mix.raise("crew.verify: refusing the development test key for a release")

      {:error, problems} ->
        Mix.raise("crew.verify: #{inspect(problems)}")
    end
  end

  defp refuse_test_key(public, true) do
    if Keys.test_key?(public), do: {:error, :test_key_for_release}, else: :ok
  end

  defp refuse_test_key(_public, _release), do: :ok
end
