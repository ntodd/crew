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
    sha = sha256(path)

    File.write!(path <> ".sha256", "#{sha}  #{Path.basename(path)}\n")
    File.write!(path <> ".sig", CrewProtocol.Auth.sign_release(version, target, sha, private))
    Path.basename(path)
  end

  @doc """
  Checks every tarball in `dir` as the control plane registers it and a
  box installs it: it matches its `.sha256`, and its `.sig` verifies
  against `public` over version, target and SHA-256. `{:ok, [file]}`, or
  `{:error, [{file, reason}]}`; a directory with no tarballs is
  `{:error, :no_tarballs}`.
  """
  def verify_dir(dir, public) do
    files = dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".tar.gz")) |> Enum.sort()

    with :ok <- check_names(files),
         [_ | _] <- files do
      case for(f <- files, reason = problem(Path.join(dir, f), public), do: {f, reason}) do
        [] -> {:ok, files}
        problems -> {:error, problems}
      end
    else
      [] -> {:error, :no_tarballs}
      {:error, _} = error -> error
    end
  end

  defp problem(path, public) do
    [_, _component, version, target] = Regex.run(@name, Path.basename(path))
    sha = sha256(path)

    with {:ok, listed} <- read(path <> ".sha256", :no_sha256),
         true <- first_word(listed) == sha || :sha256_mismatch,
         {:ok, signature} <- read(path <> ".sig", :no_signature),
         :ok <- CrewProtocol.Auth.verify_release(version, target, sha, signature, public) do
      nil
    else
      {:error, :bad_signature} -> :bad_signature
      {:error, reason} -> reason
      reason when is_atom(reason) -> reason
    end
  end

  defp read(path, missing) do
    case File.read(path) do
      {:ok, text} -> {:ok, String.trim(text)}
      {:error, _} -> {:error, missing}
    end
  end

  defp first_word(text), do: text |> String.split() |> List.first()

  defp sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
