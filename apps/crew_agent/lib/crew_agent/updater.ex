defmodule CrewAgent.Updater do
  @moduledoc """
  Installs a new agent release (`agent.update`, §20.2): Foreman's
  `ForemanAgent.Updater`, with Crew's differences.

  **Checked before anything is downloaded:** each tarball's signature
  (`CrewProtocol.Auth.verify_release/5`, over the version, this build's
  target and the tarball's SHA-256) against the release key the agent was
  installed with (`CREW_RELEASE_PUBLIC_KEY`). Without one there are no
  updates. After the download: its size and SHA-256.

  **Laid out** in `${CREW_DATA_DIR}/agent`, as the first install leaves
  it (Flatcar's `agent-install.sh`, macOS's `install-macos.sh`):

      agent/<version>/          a release: the agent tarball, and on Linux
                                crew_cache's in cache/
      agent/current -> <version>
      agent/previous -> <version>   until the new release joins
      agent/update-pending      the update in flight (JSON), until it joins
      agent/rolled-back         the marker, renamed by whatever rolled back
      agent/update/             the downloads (and on Linux root's request)

  A tarball unpacks into a directory of its own, refusing any path that
  isn't a plain relative one (no `..`, nothing absolute) and anything but
  files and directories, and must hold what this box runs.

  **Then it waits**, since running VMs survive the restart (§10.7) and
  only what's in flight doesn't: for the other operations in flight (at
  most 10 minutes), then for no VM to be `starting`, i.e. booted but
  without its payload (at most 90 s). After either bound it goes ahead.

  **On Linux, root's half** (crew-vmctl, jailer, Firecracker, the ruleset
  and their units) is installed by root from the tarballs themselves
  (`CrewAgent.Updater.RootStep`), never from anything the agent wrote.
  Once root has it, the agent moves `current`, restarts crew-cache onto
  the new release through crew-vmctl, and exits for systemd (or launchd)
  to start the new one.

  **Rolling back:** until the new release joins (`confirm/2`), `previous`
  and the marker stay. A crash loop is caught by the service manager
  (`crew-agent-rollback.service`, or `crew-launch` on macOS); a release
  that runs but doesn't join within 5 minutes is caught by the
  connection's watchdog (`rollback_due?/4`). Either way the marker is
  renamed `rolled-back`, and the release that comes back reports the
  update as failed when it joins.
  """

  alias CrewAgent.{Config, Identity, Ops, VMs}
  alias CrewAgent.Driver.VZ.Upgrade
  alias CrewAgent.Images.Download
  alias CrewAgent.Updater.RootStep
  alias CrewProtocol.Auth

  require Logger

  @pending "update-pending"
  @rolled_back "rolled-back"
  @crashes "crashes"
  @stage "update"
  @rollback_after 300
  @rollback_exit 75
  @ops_wait_ms 10 * 60_000
  @starting_wait_ms 90_000
  @version ~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}(-[0-9A-Za-z.]{1,32})?\z/

  @units ~w(crew-net-site4.service crew-net-site4.timer crew-net.service crew-vmctl.socket crew-vmctl@.service)

  # What each OS's release must hold (packaging/release/build-*.sh).
  @required %{
    "linux" =>
      ~w(bin/crew_agent bin/crew-vmctl bin/jailer bin/firecracker etc/nft.conf etc/connlimit.rules
         cache/bin/crew_cache) ++ Enum.map(@units, &"etc/systemd/#{&1}"),
    "darwin" => ~w(bin/crew_agent bin/crew-launch bin/crew-vz share/sandbox.sb)
  }

  @type result :: {:ok, map()} | {:error, String.t(), String.t()}

  @doc "How long the update waits for other operations in flight (§20.2)."
  def ops_wait_ms, do: @ops_wait_ms

  @doc "How long it waits for no VM to be starting (§10.7)."
  def starting_wait_ms, do: @starting_wait_ms

  @doc """
  Installs `payload`'s release. Answers `restart: true` when the agent
  should exit for the new release to start, with `from`, the version
  running now. Options (the defaults are the real ones):

  - `:op_id`, the update's operation, recorded in the marker;
  - `:running` and `:target`, this build's version and target;
  - `:busy?` and `:starting?`, polled every `:poll_ms` for at most
    `:ops_wait_ms` and `:starting_wait_ms`;
  - `:root_step`, given the staged tarballs, and `:after_swap` (on a
    Firecracker box, `RootStep.install/2` and crew-cache's restart);
  - `:download`, `CrewAgent.Images.Download.fetch/4`'s options.
  """
  @spec run(map(), Config.t(), keyword()) :: result()
  def run(payload, %Config{} = config, opts \\ []) do
    root = Config.agent_dir(config)
    lock = {{__MODULE__, root}, self()}
    :global.trans(lock, fn -> install(payload, config, opts) end, [node()], :infinity)
  end

  defp install(p, config, opts) do
    root = Config.agent_dir(config)
    running = Keyword.get_lazy(opts, :running, &Identity.version/0)

    cond do
      p.version == running ->
        stay(root, running)

      current_version(root) == p.version ->
        Logger.info("agent #{p.version} is already installed; restarting into it")
        {:ok, %{"version" => p.version, "restart" => true, "from" => running}}

      true ->
        fresh(p, config, root, running, opts)
    end
  end

  # The control plane wants the release that's running: if an update
  # moved current away from it and hasn't restarted yet, it's put back.
  defp stay(root, running) do
    if current_version(root) not in [nil, running] and File.dir?(Path.join(root, running)) do
      :ok = relink(root, "current", running)
      File.rm(Path.join(root, "previous"))
      File.rm(Path.join(root, @pending))
    end

    {:ok, %{"version" => running, "restart" => false}}
  end

  defp fresh(p, config, root, running, opts) do
    target = Keyword.get_lazy(opts, :target, &target/0)
    os = target |> String.split("-") |> hd()
    stage = Path.join(root, @stage)

    result =
      with :ok <- check_version(p.version),
           {:ok, key} <- release_key(config),
           :ok <- verify(p, "the agent", p.version, target, key),
           {:ok, cache} <- cache_for(p, os),
           :ok <- verify(cache, "crew_cache", p.version, target, key),
           :ok <- reset(stage),
           Logger.info("downloading agent #{p.version} for #{target}"),
           {:ok, agent_tar} <- download(p, Path.join(stage, "agent.tar.gz"), config, opts),
           {:ok, cache_tar} <- download(cache, Path.join(stage, "cache.tar.gz"), config, opts),
           {:ok, partial} <- unpack(root, p.version, agent_tar, cache_tar, os),
           {:ok, placed} <- place(partial, root, p.version) do
        staged = %{
          version: p.version,
          target: target,
          agent: %{path: agent_tar, sha256: p.sha256, signature: p.signature},
          cache: cache && %{path: cache_tar, sha256: cache.sha256, signature: cache.signature}
        }

        finish(p, config, root, running, staged, placed, opts)
      end

    File.rm_rf(stage)
    result
  end

  defp finish(p, config, root, running, staged, placed, opts) do
    wait(opts)

    case root_step(config, opts).(staged) do
      :ok ->
        swap(root, p.version, %{
          "op_id" => opts[:op_id],
          "version" => p.version,
          "from" => running,
          "installed_at" => System.os_time(:second)
        })

        after_swap(config, opts).()
        Logger.info("installed agent #{p.version}; restarting into it")
        {:ok, %{"version" => p.version, "restart" => true, "from" => running}}

      {:error, message} ->
        if placed == :new, do: File.rm_rf(Path.join(root, p.version))
        {:error, "root_install_failed", "root didn't install #{p.version}: #{message}"}
    end
  end

  # -- checks --------------------------------------------------------------------

  defp check_version(version) do
    if Regex.match?(@version, version),
      do: :ok,
      else: {:error, "bad_version", "#{inspect(version)} isn't a release version"}
  end

  defp release_key(%Config{release_public_key: <<_::binary-size(32)>> = key}), do: {:ok, key}

  defp release_key(_),
    do:
      {:error, "no_release_key",
       "this agent has no release key (CREW_RELEASE_PUBLIC_KEY), so it can't check an update"}

  defp verify(nil, _what, _version, _target, _key), do: :ok

  defp verify(file, what, version, target, key) do
    case Auth.verify_release(version, target, file.sha256, file.signature, key) do
      :ok ->
        :ok

      {:error, _} ->
        {:error, "bad_signature",
         "#{what}'s signature for #{version} (#{target}) doesn't verify against the release key"}
    end
  end

  # crew_cache runs beside the agent on Linux, at the same version (§20.2).
  defp cache_for(%{cache: %{} = cache}, "linux"), do: {:ok, cache}

  defp cache_for(_p, "linux"),
    do: {:error, "no_cache", "the update has no crew_cache tarball, which this box runs"}

  defp cache_for(_p, _os), do: {:ok, nil}

  # -- downloading ---------------------------------------------------------------

  defp reset(dir) do
    File.rm_rf(dir)

    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "install_failed", "can't make #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp download(nil, _path, _config, _opts), do: {:ok, nil}

  defp download(file, path, config, opts) do
    url = download_url(file.url, config.url)

    case Download.fetch(url, path, file.size, Keyword.get(opts, :download, [])) do
      {:ok, sha} when sha == file.sha256 ->
        {:ok, path}

      {:ok, _other} ->
        {:error, "sha256_mismatch", "#{Path.basename(path)} doesn't match its SHA-256"}

      {:error, reason} ->
        {:error, "download_failed", "downloading #{Path.basename(path)} failed: #{reason}"}
    end
  end

  # The control plane names its own public URL, which a box can't always
  # reach; the agent downloads from where it already talks to it
  # (CREW_URL). The signature doesn't cover the URL (Foreman's).
  defp download_url(url, agent_url) when is_binary(agent_url) and agent_url != "" do
    origin = URI.parse(agent_url)

    scheme =
      case origin.scheme do
        "wss" -> "https"
        "ws" -> "http"
        other -> other
      end

    %{URI.parse(url) | scheme: scheme, host: origin.host, port: origin.port}
    |> URI.to_string()
  end

  defp download_url(url, _), do: url

  # -- unpacking -----------------------------------------------------------------

  defp unpack(root, version, agent_tar, cache_tar, os) do
    partial = Path.join(root, ".#{version}.partial")
    File.rm_rf(partial)

    result =
      with :ok <- File.mkdir_p(partial),
           :ok <- extract(agent_tar, partial),
           :ok <- extract(cache_tar, Path.join(partial, "cache")),
           :ok <- check_required(partial, os) do
        seal(partial)
        {:ok, partial}
      end

    case result do
      {:ok, partial} ->
        {:ok, partial}

      {:error, code, message} ->
        File.rm_rf(partial)
        {:error, code, message}

      {:error, reason} ->
        File.rm_rf(partial)
        {:error, "install_failed", "can't unpack #{version}: #{inspect(reason)}"}
    end
  end

  defp extract(nil, _dest), do: :ok

  defp extract(tarball, dest) do
    tar = String.to_charlist(tarball)

    with {:ok, entries} <- :erl_tar.table(tar, [:compressed, :verbose]),
         :ok <- check_entries(entries, Path.basename(tarball)),
         :ok <- File.mkdir_p(dest),
         :ok <- :erl_tar.extract(tar, [:compressed, {:cwd, String.to_charlist(dest)}]) do
      :ok
    else
      {:error, code, message} ->
        {:error, code, message}

      {:error, reason} ->
        {:error, "bad_release", "can't unpack #{Path.basename(tarball)}: #{inspect(reason)}"}
    end
  end

  # Plain relative paths only, and only files and directories: a link
  # could point the next entry anywhere.
  defp check_entries(entries, tarball) do
    Enum.find_value(entries, :ok, fn {name, type, _size, _mtime, _mode, _uid, _gid} ->
      name = to_string(name)
      parts = Path.split(name)

      cond do
        Path.type(name) != :relative or ".." in parts ->
          {:error, "bad_release", "#{tarball} has an unsafe path: #{inspect(name)}"}

        type not in [:regular, :directory] ->
          {:error, "bad_release",
           "#{tarball} has a #{type} at #{inspect(name)}; only files and directories are allowed"}

        true ->
          nil
      end
    end)
  end

  defp check_required(dir, os) do
    case Enum.reject(
           Map.get(@required, os, ["bin/crew_agent"]),
           &File.regular?(Path.join(dir, &1))
         ) do
      [] -> :ok
      missing -> {:error, "bad_release", "the release has no #{Enum.join(missing, ", ")}"}
    end
  end

  # Nobody but the agent writes its release; crewcache (Linux) and _crewvm
  # (macOS) read and run parts of it.
  defp seal(dir) do
    File.chmod(dir, 0o755)

    for name <- File.ls!(dir) do
      path = Path.join(dir, name)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          seal(path)

        {:ok, %File.Stat{type: :regular, mode: mode}} ->
          File.chmod(path, Bitwise.band(Bitwise.bor(mode, 0o444), 0o755))

        _ ->
          :ok
      end
    end

    :ok
  end

  # Moves the unpacked release into place beside the current one. A
  # directory of that version already there is replaced, unless it can't
  # be: the first install's, which is root's and read-only, so as it was
  # checked then.
  defp place(partial, root, version) do
    dest = Path.join(root, version)

    case File.rm_rf(dest) do
      {:ok, _} ->
        case File.rename(partial, dest) do
          :ok ->
            {:ok, :new}

          {:error, reason} ->
            {:error, "install_failed", "can't place #{version}: #{:file.format_error(reason)}"}
        end

      {:error, _reason, _file} ->
        File.rm_rf(partial)

        if File.regular?(Path.join(dest, "bin/crew_agent")),
          do: {:ok, :kept},
          else: {:error, "install_failed", "can't replace #{dest}"}
    end
  end

  # -- waiting -------------------------------------------------------------------

  defp wait(opts) do
    op_id = opts[:op_id]
    poll = Keyword.get(opts, :poll_ms, 1_000)
    busy? = Keyword.get(opts, :busy?, fn -> Enum.any?(Ops.in_flight(), &(&1 != op_id)) end)
    starting? = Keyword.get(opts, :starting?, fn -> VMs.starting_count() > 0 end)

    if await(busy?, poll, Keyword.get(opts, :ops_wait_ms, @ops_wait_ms)) == :timeout,
      do: Logger.warning("updating with operations still in flight")

    if await(starting?, poll, Keyword.get(opts, :starting_wait_ms, @starting_wait_ms)) ==
         :timeout,
       do: Logger.warning("updating with a VM still starting; it'll be stopped (agent_restart)")

    :ok
  end

  @doc false
  def await(busy?, poll, max_ms) do
    deadline = System.monotonic_time(:millisecond) + max_ms
    do_await(busy?, poll, deadline)
  end

  defp do_await(busy?, poll, deadline) do
    cond do
      not busy?.() ->
        :idle

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(poll)
        do_await(busy?, poll, deadline)
    end
  end

  defp root_step(config, opts) do
    Keyword.get_lazy(opts, :root_step, fn ->
      if config.driver == "firecracker",
        do: &RootStep.install(config, &1),
        else: fn _staged -> :ok end
    end)
  end

  defp after_swap(config, opts) do
    Keyword.get_lazy(opts, :after_swap, fn ->
      if config.driver == "firecracker",
        do: fn -> RootStep.restart_cache(config) end,
        else: fn -> :ok end
    end)
  end

  # -- the swap and after --------------------------------------------------------

  defp swap(root, version, marker) do
    # `previous` is what to go back to: the last release that joined. Not
    # one installed over another before a restart, which never did.
    unconfirmed? = File.exists?(Path.join(root, @pending)) and link(root, "previous") != nil

    with false <- unconfirmed?,
         prev when is_binary(prev) and prev != version <- link(root, "current") do
      :ok = relink(root, "previous", prev)
    end

    write_json!(Path.join(root, @pending), marker)
    File.rm(Path.join(root, @rolled_back))
    File.rm(Path.join(root, @crashes))
    :ok = relink(root, "current", version)
  end

  @doc """
  After a join. The release `current` points at has joined, so there's
  nothing to roll back to any more: `:confirmed`, and old releases are
  pruned. A release that came back after a rollback answers
  `{:rolled_back, info}` once, for the control plane to hear the update
  failed. Otherwise `:ok`: the old release, still waiting to restart into
  the new one, leaves the rollback state to it. `:keep` names releases to
  keep however old (crew-vzd's own).
  """
  @spec confirm(Config.t(), keyword()) :: :ok | :confirmed | {:rolled_back, map()}
  def confirm(%Config{} = config, opts \\ []) do
    root = Config.agent_dir(config)
    running = Keyword.get_lazy(opts, :running, &Identity.version/0)
    keep = Keyword.get(opts, :keep, [])

    cond do
      File.exists?(Path.join(root, @rolled_back)) ->
        info = rolled_back(root, running)
        File.rm(Path.join(root, @rolled_back))
        prune(root, [running | keep])
        {:rolled_back, info}

      File.exists?(Path.join(root, @pending)) and current_version(root) == running ->
        Logger.info("agent #{running} joined; keeping it")
        File.rm(Path.join(root, "previous"))
        File.rm(Path.join(root, @pending))
        File.rm(Path.join(root, @crashes))
        prune(root, [running | keep])
        :confirmed

      true ->
        :ok
    end
  end

  defp rolled_back(root, running) do
    marker =
      case read_json(Path.join(root, @rolled_back)) do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    version = marker["version"]

    reason =
      marker["reason"] ||
        "it crash-looped, and the service manager switched back to the release before it"

    %{
      op_id: marker["op_id"],
      version: version,
      reason: reason,
      message:
        "#{version || "the update"} didn't take on this box (#{reason}); back on #{running}"
    }
  end

  @doc """
  True when an update hasn't joined, there's a release to go back to,
  and this process (running since `running_since`) has had 5 minutes.
  Timed from the later of the install and the start, so a box shut down
  right after an update gets the whole 5 minutes when it boots. Only for
  the release `current` points at.
  """
  @spec rollback_due?(Config.t(), integer(), integer(), String.t()) :: boolean()
  def rollback_due?(%Config{} = config, running_since, now, running \\ Identity.version()) do
    root = Config.agent_dir(config)

    with true <- current_version(root) == running,
         {:ok, %{"installed_at" => at}} when is_integer(at) <-
           read_json(Path.join(root, @pending)),
         prev when is_binary(prev) <- link(root, "previous") do
      now - max(at, running_since) >= @rollback_after
    else
      _ -> false
    end
  end

  @doc """
  The exit status that tells systemd not to restart the agent but to
  fail it, so `crew-agent-rollback.service` (its `OnFailure=`) runs:
  `RestartPreventExitStatus=` in `crew-agent.service`.
  """
  def rollback_exit_status, do: @rollback_exit

  @doc """
  The connection's watchdog, while the agent hasn't joined: once
  `rollback_due?/4`, answers how to stop. On a Firecracker box root's
  half has to move back too, so the agent leaves it to
  `crew-agent-rollback.service` (`{:stop, 75}`); elsewhere it switches
  back itself and exits to be restarted (`{:stop, 1}`).
  """
  @spec watchdog(Config.t(), integer(), integer(), String.t()) :: :ok | {:stop, integer()}
  def watchdog(%Config{} = config, running_since, now, running \\ Identity.version()) do
    cond do
      not rollback_due?(config, running_since, now, running) ->
        :ok

      config.driver == "firecracker" ->
        Logger.error("agent #{running} hasn't joined since it was installed; rolling back")
        {:stop, @rollback_exit}

      true ->
        Logger.error("agent #{running} hasn't joined since it was installed; rolling back")

        with {:error, reason} <-
               rollback(config, "it didn't join the control plane within 5 minutes"),
             do: Logger.error("couldn't roll back: #{inspect(reason)}")

        {:stop, 1}
    end
  end

  @doc """
  Switches `current` back to `previous`, and renames the marker
  `rolled-back`, with `reason`, for the release it lands on to report.
  """
  @spec rollback(Config.t(), String.t()) :: :ok | {:error, term()}
  def rollback(%Config{} = config, reason) do
    root = Config.agent_dir(config)

    with prev when is_binary(prev) <- release_link(root, "previous") || {:error, :no_previous},
         :ok <- relink(root, "current", prev) do
      marker =
        case read_json(Path.join(root, @pending)) do
          {:ok, %{} = m} -> m
          _ -> %{}
        end

      write_json!(Path.join(root, @rolled_back), Map.put(marker, "reason", reason))
      File.rm(Path.join(root, @pending))
      File.rm(Path.join(root, "previous"))
      :ok
    end
  end

  @doc "The version `current` points at, if it's a release here."
  @spec current_version(Path.t()) :: String.t() | nil
  def current_version(root), do: release_link(root, "current")

  # A link's target when it's a release's name: never a path.
  defp release_link(root, name) do
    case link(root, name) do
      version when is_binary(version) -> if Regex.match?(@version, version), do: version
      nil -> nil
    end
  end

  @doc """
  Releases to keep however old: on macOS, the one crew-vzd still runs
  from until it restarts (`CrewAgent.Driver.VZ.Upgrade`).
  """
  @spec keep(Config.t()) :: [String.t()]
  def keep(%Config{driver: "vz"} = config) do
    case Upgrade.vzd_version(config) do
      version when is_binary(version) ->
        if Regex.match?(@version, version), do: [version], else: []

      nil ->
        []
    end
  end

  def keep(%Config{}), do: []

  # Keeps the releases `current` and `previous` point at, and `keep`.
  defp prune(root, keep) do
    keep =
      MapSet.new(keep ++ Enum.reject([link(root, "current"), link(root, "previous")], &is_nil/1))

    for name <- File.ls!(root),
        Regex.match?(@version, name) or String.ends_with?(name, ".partial"),
        not MapSet.member?(keep, name),
        do: File.rm_rf(Path.join(root, name))

    :ok
  rescue
    e -> Logger.warning("couldn't prune old releases: #{Exception.message(e)}")
  end

  @doc "This build's release target, e.g. `linux-arm64`."
  def target do
    arch =
      case :erlang.system_info(:system_architecture)
           |> to_string()
           |> String.split("-")
           |> hd() do
        "aarch64" -> "arm64"
        "x86_64" -> "amd64"
        other -> other
      end

    os =
      case :os.type() do
        {:unix, :linux} -> "linux"
        {:unix, :darwin} -> "darwin"
        {_, other} -> to_string(other)
      end

    "#{os}-#{arch}"
  end

  # -- files ---------------------------------------------------------------------

  defp link(root, name) do
    case File.read_link(Path.join(root, name)) do
      {:ok, target} -> if Path.split(target) == [target], do: target
      {:error, _} -> nil
    end
  end

  # A new link renamed over the old one, so `current` always exists.
  defp relink(root, name, target) do
    tmp = Path.join(root, ".#{name}.#{System.unique_integer([:positive])}")

    with :ok <- File.ln_s(target, tmp),
         :ok <- File.rename(tmp, Path.join(root, name)) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp write_json!(path, map) do
    tmp = "#{path}.#{System.unique_integer([:positive])}"
    File.write!(tmp, Jason.encode!(map))
    File.rename!(tmp, path)
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end
end
