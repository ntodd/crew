defmodule CrewImage.Release do
  @moduledoc """
  Signs a release's agent and cache tarballs (spec §20.1 item 6): for each
  `crew-<agent|cache>-<version>-<target>.tar.gz`, `<file>.sha256` (as
  `sha256sum` writes it) and `<file>.sig`, the ed25519 signature over
  `CrewProtocol.Auth.release_message/3` (version, target and SHA-256).
  """

  @name ~r/\Acrew-(agent|cache)-(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)-(linux-amd64|linux-arm64|darwin-arm64)\.tar\.gz\z/

  @doc "Signs every tarball in `dir`. `{:ok, [file]}`, or the first bad name."
  def sign_dir(dir, private) do
    files = dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".tar.gz")) |> Enum.sort()

    with :ok <- check_names(files) do
      {:ok, Enum.map(files, &sign(Path.join(dir, &1), private))}
    end
  end

  defp check_names(files) do
    case Enum.find(files, &(not Regex.match?(@name, &1))) do
      nil -> :ok
      bad -> {:error, {:bad_name, bad}}
    end
  end

  defp sign(path, private) do
    [_, _component, version, target] = Regex.run(@name, Path.basename(path))

    sha =
      path
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    File.write!(path <> ".sha256", "#{sha}  #{Path.basename(path)}\n")
    File.write!(path <> ".sig", CrewProtocol.Auth.sign_release(version, target, sha, private))
    Path.basename(path)
  end
end
