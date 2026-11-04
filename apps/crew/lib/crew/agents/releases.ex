defmodule Crew.Agents.Releases do
  @moduledoc """
  The signed agent and crew_cache tarballs this control plane knows
  (§20.1, §20.2), Foreman's `Agents.Releases` for Crew.

  CI builds and signs each release; the signing key never touches the
  control plane. The control plane's image carries its release's
  tarballs in CREW_AGENT_RELEASE_DIR, registered at every boot as
  `Crew.Images.register_bundle/1` registers its manifests:

      crew-<agent|cache>-<version>-<target>.tar.gz
      crew-<agent|cache>-<version>-<target>.tar.gz.sha256   <hex>[  <file>]
      crew-<agent|cache>-<version>-<target>.tar.gz.sig      CrewProtocol.Auth.sign_release/4, base64

  A tarball is registered only if it matches its `.sha256` and its
  signature verifies against CREW_RELEASE_PUBLIC_KEY. Targets are
  `linux-amd64`, `linux-arm64` and `darwin-arm64`; crew_cache ships for
  Linux only, at the agent's version.

  A Flatcar box's first install (`Crew.Boxes.Flatcar`) downloads the
  newest release that has both tarballs for its target, from the GitHub
  release: never from the control plane, except in development
  (CREW_DEV=1), where the control plane serves the files it holds.
  """
  import Ecto.Query

  require Logger

  alias Crew.Agents.Release
  alias Crew.Repo

  @components ~w(agent cache)
  @targets ~w(linux-amd64 linux-arm64 darwin-arm64)
  @version ~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}(-[0-9A-Za-z.]{1,32})?\z/
  @file_pattern ~r/\Acrew-(agent|cache)-(\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z.]{1,32})?)-((?:linux|darwin)-(?:amd64|arm64))\.tar\.gz\z/

  def components, do: @components
  def targets, do: @targets

  def list, do: Repo.all(from r in Release, order_by: [desc: r.inserted_at])

  def get(component, version, target),
    do: Repo.get_by(Release, component: component, version: version, target: target)

  @doc "A release file's name, as CI publishes it."
  def file_name(component, version, target), do: "crew-#{component}-#{version}-#{target}.tar.gz"

  @doc """
  Which release a file name is, or `:error`: `{component, version,
  target}` for a name `file_name/3` would make.
  """
  def parse_file_name(name) when is_binary(name) do
    case Regex.run(@file_pattern, name) do
      [_, component, version, target] when target in @targets -> {component, version, target}
      _ -> :error
    end
  end

  def parse_file_name(_), do: :error

  @doc """
  The newest release a new box on `target` installs: the highest version
  with both an agent and a cache tarball whose files are here, passing
  over prereleases unless there's nothing else.
  """
  def install_set(target) do
    releases =
      Repo.all(from r in Release, where: r.target == ^target)
      |> Enum.filter(&File.regular?(&1.path))
      |> Enum.group_by(& &1.version)

    complete =
      for {version, rows} <- releases,
          agent = Enum.find(rows, &(&1.component == "agent")),
          cache = Enum.find(rows, &(&1.component == "cache")),
          into: %{},
          do: {version, %{version: version, agent: agent, cache: cache}}

    case complete |> Map.keys() |> highest() do
      nil -> {:error, :no_release}
      version -> {:ok, complete[version]}
    end
  end

  # The highest version, passing over prereleases unless there's nothing
  # else (Foreman's).
  defp highest(versions) do
    {pre, stable} =
      for version <- versions, {:ok, parsed} <- [Version.parse(version)] do
        {parsed, version}
      end
      |> Enum.split_with(fn {parsed, _} -> parsed.pre != [] end)

    case Enum.max_by(if(stable == [], do: pre, else: stable), &elem(&1, 0), Version, fn -> nil end) do
      {_, version} -> version
      nil -> nil
    end
  end

  @doc """
  Where a box downloads a release file from: its GitHub release
  (`<github web>/<CREW_UPDATE_REPO>/releases/download/v<version>/<file>`),
  or in development, when the control plane has the file, the control
  plane's own `/agent/releases/<version>/<target>/<file>`.
  """
  def url(%Release{} = release) do
    file = file_name(release.component, release.version, release.target)

    if Crew.Config.dev?() and File.regular?(release.path),
      do: "#{Crew.Config.base_url()}/agent/releases/#{release.version}/#{release.target}/#{file}",
      else: github_url(release.version, file)
  end

  def github_url(version, file) do
    repo = Application.get_env(:crew, :update_repo, "ntodd/crew")
    "#{Crew.GitHub.Client.web_url()}/#{repo}/releases/download/v#{version}/#{file}"
  end

  # -- registering ---------------------------------------------------------------

  @doc """
  Registers the release tarballs in `dir` (CREW_AGENT_RELEASE_DIR), each
  with its `.sha256` and `.sig`. The same tarball again is left as it
  is. Returns how many registered, and the files that didn't with why.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # `dir` is CREW_AGENT_RELEASE_DIR, the operator's; the files are the
  # ones in it whose names parse_file_name/1 accepts.
  def register_bundle(dir) when is_binary(dir) do
    files =
      case File.ls(dir) do
        {:ok, files} -> Enum.sort(files)
        {:error, _} -> []
      end

    results =
      for file <- files, {component, version, target} <- [parse_file_name(file)] do
        path = Path.join(dir, file)

        case register_file(path, component, version, target) do
          {:ok, release} ->
            {:ok, release}

          {:error, reason} ->
            Logger.warning("agent release #{file} wasn't registered: #{reason}")
            {:error, {file, reason}}
        end
      end

    %{
      registered: Enum.count(results, &match?({:ok, _}, &1)),
      failed: for({:error, f} <- results, do: f)
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The path is a file found in the release directory (register_bundle/1).
  defp register_file(path, component, version, target) do
    with {:ok, expected} <- read_sha256(path <> ".sha256"),
         {:ok, signature} <- read_text(path <> ".sig"),
         {:ok, sha} <- sha256(path),
         true <- sha == expected || {:error, "the tarball doesn't match its .sha256 (SHA-256)"} do
      register(component, version, target, path, sha, signature)
    end
  end

  @doc """
  Registers one tarball at `path` whose SHA-256 is `sha`, if `signature`
  verifies against the release key.
  """
  def register(component, version, target, path, sha, signature)
      when component in @components and target in @targets do
    with true <- Regex.match?(@version, version) || {:error, "invalid version"},
         key when is_binary(key) <-
           Crew.Config.release_public_key() ||
             {:error, "no release key (CREW_RELEASE_PUBLIC_KEY)"},
         :ok <- CrewProtocol.Auth.verify_release(version, target, sha, signature, key) do
      store(component, version, target, path, sha, signature)
    else
      {:error, :bad_signature} -> {:error, "the signature doesn't verify against the release key"}
      error -> error
    end
  end

  def register(_, _, _, _, _, _), do: {:error, "invalid component or target"}

  defp store(component, version, target, path, sha, signature) do
    %Release{
      component: component,
      version: version,
      target: target,
      sha256: sha,
      signature: signature,
      size: File.stat!(path).size,
      path: path
    }
    |> Repo.insert(
      on_conflict: {:replace, [:sha256, :signature, :size, :path]},
      conflict_target: [:component, :version, :target]
    )
    |> case do
      # On a conflict the struct carries an id that wasn't stored.
      {:ok, _} -> {:ok, get(component, version, target)}
      error -> error
    end
  end

  defp read_sha256(path) do
    with {:ok, text} <- read_text(path) do
      sha = text |> String.split() |> List.first() |> to_string()

      if sha =~ ~r/\A[0-9a-fA-F]{64}\z/,
        do: {:ok, String.downcase(sha)},
        else: {:error, "the .sha256 isn't a SHA-256 (SHA-256)"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_text(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, String.trim(text)}
      {:error, _} -> {:error, "no #{Path.basename(path)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sha256(path) do
    {:ok,
     path
     |> File.stream!(1_048_576)
     |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
     |> :crypto.hash_final()
     |> Base.encode16(case: :lower)}
  rescue
    e in File.Error -> {:error, Exception.message(e)}
  end
end
