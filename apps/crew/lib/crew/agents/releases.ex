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

  @doc "The release target for an agent's `os` and `arch` (its join's), e.g. `linux-arm64`."
  def target(os, arch) when os in ["linux", "darwin"] and arch in ["x64", "arm64"],
    do: "#{os}-#{if arch == "x64", do: "amd64", else: "arm64"}"

  def target(_os, _arch), do: nil

  @doc """
  The versions a box on `target` can be updated to, newest first: an
  agent tarball here and, on Linux, crew_cache's at the same version
  (§20.2: the cache updates with the agent).
  """
  def versions(target) when target in @targets do
    Repo.all(from r in Release, where: r.target == ^target)
    |> Enum.filter(&File.regular?(&1.path))
    |> Enum.group_by(& &1.version)
    |> Enum.filter(fn {_version, rows} -> complete?(target, rows) end)
    |> Enum.flat_map(fn {version, _} ->
      case Version.parse(version) do
        {:ok, parsed} -> [{parsed, version}]
        :error -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), {:desc, Version})
    |> Enum.map(&elem(&1, 1))
  end

  def versions(_target), do: []

  defp complete?("linux-" <> _, rows),
    do:
      Enum.any?(rows, &(&1.component == "agent")) and Enum.any?(rows, &(&1.component == "cache"))

  defp complete?(_target, rows), do: Enum.any?(rows, &(&1.component == "agent"))

  @doc """
  The version boxes on `target` follow unless pinned: the newest they
  can be updated to, passing over prereleases unless there's nothing
  else. Nil when there's none.
  """
  def fleet_version(target), do: target |> versions() |> highest()

  @doc """
  The tarballs an update to `version` sends a box on `target`, each
  checked again first (`intact?/1`), or nil.
  """
  def update_set(target, version) do
    with true <- version in versions(target),
         agent = get("agent", version, target),
         cache = if(String.starts_with?(target, "linux-"), do: get("cache", version, target)),
         true <- Enum.all?(Enum.reject([agent, cache], &is_nil/1), &intact?/1) do
      %{agent: agent, cache: cache}
    else
      _ -> nil
    end
  end

  @doc """
  Where an agent downloads an update from: the control plane's own copy
  (§20.2, Foreman's). Only a first install downloads from the GitHub
  release. The agent swaps in the host it reaches the control plane at.
  """
  def update_url(%Release{} = release) do
    file = file_name(release.component, release.version, release.target)
    "#{Crew.Config.base_url()}/agent/releases/#{release.version}/#{release.target}/#{file}"
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

    registered = Enum.count(results, &match?({:ok, _}, &1))

    # Boxes online behind a release that just arrived get it now; the
    # rest when they join.
    if registered > 0, do: Crew.Agents.Updates.released()

    %{
      registered: registered,
      failed: for({:error, f} <- results, do: f),
      releases: for({:ok, r} <- results, do: r)
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
    with {:ok, path} <- keep_copy(path, sha, signature) do
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
  end

  # -- the control plane's own copies --------------------------------------------

  @doc """
  Where the control plane keeps its own copies of the tarballs it
  registers (CREW_AGENT_STORE_DIR, on its data volume). An image carries
  only its own release's tarballs; a box pinned to an older version
  still needs that version's after an upgrade (§20.2). Each copy has its
  `.sha256` and `.sig` beside it, so the store registers again at boot
  like the image's directory.
  """
  def store_dir do
    case Application.get_env(:crew, :agent_store_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(System.tmp_dir!(), "crew-agent-releases")
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # `path` is a tarball register_bundle/1 found and checked; the copy is
  # named after it, in the store.
  defp keep_copy(path, sha, signature) do
    store = Path.expand(store_dir())
    dest = Path.join(store, Path.basename(path))

    cond do
      Path.dirname(Path.expand(path)) == store ->
        {:ok, path}

      sha256(dest) == {:ok, sha} ->
        write_beside(dest, sha, signature)

      true ->
        # Copied beside it and renamed into place, so nothing ever finds
        # half a file (Foreman's).
        partial = "#{dest}.partial-#{System.unique_integer([:positive])}"

        with :ok <- File.mkdir_p(store),
             :ok <- File.cp(path, partial),
             :ok <- File.rename(partial, dest) do
          write_beside(dest, sha, signature)
        else
          {:error, reason} ->
            File.rm(partial)
            {:error, "couldn't keep a copy in #{store}: #{:file.format_error(reason)}"}
        end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_beside(dest, sha, signature) do
    File.write!(dest <> ".sha256", "#{sha}  #{Path.basename(dest)}\n")
    File.write!(dest <> ".sig", signature)
    {:ok, dest}
  end

  @doc """
  Registers what boots with: the image's directory (copied into the
  store) and the store itself, then prunes the store.
  """
  def register_at_boot(image_dir) do
    bundle = if is_binary(image_dir) and image_dir != "", do: register_bundle(image_dir)
    register_bundle(store_dir())

    keep = for %Release{version: v} <- (bundle && bundle.releases) || [], uniq: true, do: v
    prune(keep)
  end

  @doc """
  Drops the copies, and their rows, nothing needs: kept are the newest
  three versions per target, every version a box is pinned to or runs,
  and `keep`.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # Only files in the store are removed.
  def prune(keep \\ []) do
    boxes = Repo.all(from b in Crew.Boxes.Box, select: {b.desired_agent_version, b.agent_version})
    needed = MapSet.new(keep ++ Enum.flat_map(boxes, &Tuple.to_list/1))
    store = Path.expand(store_dir())

    for {_target, rows} <- Enum.group_by(Repo.all(Release), & &1.target),
        newest = rows |> Enum.map(& &1.version) |> Enum.uniq() |> newest(3),
        row <- rows,
        row.version not in newest and not MapSet.member?(needed, row.version) do
      if Path.dirname(Path.expand(row.path)) == store,
        do: Enum.each(["", ".sha256", ".sig"], &File.rm(row.path <> &1))

      Repo.delete(row)
    end

    :ok
  end

  defp newest(versions, n) do
    versions
    |> Enum.flat_map(fn v ->
      case Version.parse(v) do
        {:ok, parsed} -> [{parsed, v}]
        :error -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), {:desc, Version})
    |> Enum.take(n)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The release's file is the one registered: its size and SHA-256, and a
  signature that verifies against the release key now. Checked before a
  box is sent it; a stored copy that isn't is removed, so the box page
  says the version's files aren't here.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def intact?(%Release{} = release) do
    ok = same_file?(release) and signed?(release)

    if not ok and Path.dirname(Path.expand(release.path)) == Path.expand(store_dir()) do
      Logger.error("#{Path.basename(release.path)} isn't what was registered; removing it")
      Enum.each(["", ".sha256", ".sig"], &File.rm(release.path <> &1))
    end

    ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp same_file?(release) do
    case File.stat(release.path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == release.size ->
        sha256(release.path) == {:ok, release.sha256}

      _ ->
        false
    end
  end

  defp signed?(release) do
    case Crew.Config.release_public_key() do
      nil ->
        false

      key ->
        CrewProtocol.Auth.verify_release(
          release.version,
          release.target,
          release.sha256,
          release.signature,
          key
        ) == :ok
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
