defmodule CrewGuest.System.Linux do
  @moduledoc """
  The job VM's `CrewGuest.System`: crew-guest runs as root under systemd
  in the guest image (§13.1, §13.5).

  Every function also takes `opts` for tests: `:root`, a directory that
  stands in for `/`, and `:run`, which runs a command (`(cmd, args) ->
  :ok | {:error, term}`).
  """

  @behaviour CrewGuest.System

  require Logger

  alias CrewGuest.{EnvFile, Systemd}

  @nameserver "10.199.0.1"
  @ca_file "/usr/local/share/ca-certificates/crew-cache.crt"
  @bundle "/etc/ssl/certs/ca-certificates.crt"
  @ca_env [
    {"SSL_CERT_FILE", @bundle},
    {"NODE_EXTRA_CA_CERTS", @ca_file},
    {"REQUESTS_CA_BUNDLE", @bundle},
    {"CURL_CA_BUNDLE", @bundle}
  ]

  @impl true
  def setup_network(_cfg, opts \\ []) do
    resolv = path(opts, "/etc/resolv.conf")
    tmp = resolv <> ".crew"

    # Replacing the file, rather than writing through it, also replaces
    # the symlink to systemd-resolved's stub that Ubuntu ships.
    with :ok <- File.write(tmp, "nameserver #{@nameserver}\n"),
         :ok <- File.chmod(tmp, 0o644),
         :ok <- File.rename(tmp, resolv) do
      File.write(path(opts, "/proc/sys/net/ipv6/conf/eth0/disable_ipv6"), "1")
    end
  end

  @impl true
  def resize_root(_cfg, opts \\ []), do: run(opts, "resize2fs", ["/dev/vda"])

  @impl true
  def install_ca(cfg, pem, opts \\ []) do
    with :ok <- write(opts, @ca_file, pem, 0o644),
         :ok <- run(opts, "update-ca-certificates", []),
         :ok <- merge_env(opts, "/etc/environment"),
         :ok <- write(opts, "/etc/profile.d/crew-ca.sh", profile(), 0o644) do
      merge_env(opts, Path.join(cfg.runner_dir, ".env"))
    end
  end

  @doc """
  Docker's config, and with the box's cache (§15.1, Design A) a mirror
  per registry it serves: dockerd with the containerd image store reads
  `/etc/docker/certs.d/<registry>/hosts.toml` for any registry, and asks
  the cache at `https://10.199.0.1/v2/<registry>/...` first, falling back
  to the registry itself. Only pull and resolve go to the cache, never a
  push. BuildKit's docker-container driver gets the same mirrors in
  `buildkitd.toml`, for workflows that create their own builders.
  """
  @impl true
  def configure_docker(_cfg, pem, mirrors, opts \\ []) do
    hosts =
      if pem in [nil, ""],
        do: [],
        else: Enum.flat_map(mirrors, &List.wrap(CrewProtocol.Hosts.get(&1)))

    with :ok <- write(opts, "/etc/docker/daemon.json", daemon_json(opts), 0o644),
         :ok <- write_hosts_toml(opts, hosts) do
      if pem in [nil, ""],
        do: :ok,
        else: write(opts, "/etc/buildkit/buildkitd.toml", buildkitd_toml(hosts), 0o644)
    end
  end

  defp write_hosts_toml(opts, hosts) do
    Enum.reduce_while(hosts, :ok, fn h, :ok ->
      case write(opts, "/etc/docker/certs.d/#{h.prefix}/hosts.toml", hosts_toml(h), 0o644) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp hosts_toml(h) do
    """
    # Written by crew-guest: pull through the box's registry cache.
    server = "https://#{h.upstream}"

    [host."https://#{@nameserver}/v2/#{h.prefix}"]
      capabilities = ["pull", "resolve"]
      override_path = true
      ca = "#{@ca_file}"
    """
  end

  @impl true
  def notify_ready(_cfg), do: Systemd.notify("READY=1")

  @impl true
  def start_docker(_cfg, opts \\ []),
    do: run(opts, "systemctl", ["start", "containerd.service", "docker.service"])

  @impl true
  def prepare_runner(cfg, files, opts \\ []) do
    owner = "#{cfg.runner_user}:#{cfg.runner_user}"
    diag = path(opts, Path.join(cfg.runner_dir, "_diag"))

    chown_private = fn
      path, :private -> run(opts, "chown", [owner, path])
      _path, :public -> :ok
    end

    with :ok <- CrewGuest.System.write_run_files(path(opts, cfg.run_dir), files, chown_private),
         :ok <- File.mkdir_p(Path.join(diag, "pages")) do
      run(opts, "chown", ["-R", owner, diag])
    end
  end

  @impl true
  def prepare_conformance(cfg, files, opts \\ []),
    do: CrewGuest.System.write_run_files(path(opts, cfg.run_dir), files)

  @impl true
  def runner_command(cfg) do
    user = cfg.runner_user

    # setpriv execs, so the runner keeps the wrapper's pid. --reset-env
    # gives it the user's HOME, USER and a default PATH, and none of the
    # release's variables; RUNNER_MANUALLY_TRAP_SIG makes run.sh pass
    # SIGTERM on to the listener and exit with its code.
    ["setpriv", "--reuid=#{user}", "--regid=#{user}", "--init-groups", "--reset-env", "--"] ++
      ["env", "RUNNER_MANUALLY_TRAP_SIG=1" | cfg.runner_cmd]
  end

  @impl true
  def poweroff(_cfg, opts \\ []) do
    case run(opts, "systemctl", ["poweroff"]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("crew-guest: systemctl poweroff failed (#{inspect(reason)}), forcing it")
        _ = run(opts, "systemctl", ["poweroff", "--force"])
        :ok
    end
  end

  @impl true
  def stop(_cfg) do
    System.stop(0)
    :ok
  end

  # Contents

  defp profile do
    Enum.map_join(@ca_env, "", fn {k, v} -> "export #{k}=#{v}\n" end)
  end

  defp daemon_json(opts) do
    existing =
      with {:ok, json} <- File.read(path(opts, "/etc/docker/daemon.json")),
           {:ok, %{} = map} <- Jason.decode(json) do
        map
      else
        _ -> %{}
      end

    existing |> Map.put("log-driver", "local") |> Jason.encode!(pretty: true)
  end

  # The CA for BuildKit's docker-container driver, whose builders don't
  # see the guest's trust store. Workflows that create their own builders
  # pass this file (`buildkitd-config`).
  defp buildkitd_toml(hosts) do
    mirrors =
      Enum.map_join(hosts, "\n", fn h ->
        ~s([registry."#{h.prefix}"]\n  mirrors = ["#{@nameserver}/#{h.prefix}"]\n)
      end)

    "# Written by crew-guest: pull through the box's registry cache.\n" <>
      mirrors <> "\n" <> ~s([registry."#{@nameserver}"]\n  ca = ["#{@ca_file}"]\n)
  end

  # Helpers

  defp merge_env(opts, file) do
    full = path(opts, file)

    existing =
      case File.read(full) do
        {:ok, text} -> text
        {:error, _} -> ""
      end

    # Writing in place keeps the file's owner (the runner's .env is the
    # runner's).
    File.write(full, EnvFile.merge(existing, @ca_env))
  end

  defp write(opts, file, contents, mode) do
    full = path(opts, file)

    with :ok <- File.mkdir_p(Path.dirname(full)),
         :ok <- File.write(full, contents) do
      File.chmod(full, mode)
    end
  end

  defp path(opts, file), do: Path.join(Keyword.get(opts, :root, "/"), file)

  defp run(opts, cmd, args) do
    case Keyword.get(opts, :run) do
      nil -> cmd(cmd, args)
      fun -> fun.(cmd, args)
    end
  end

  defp cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {cmd, status, String.slice(out, 0, 1_000)}}
    end
  rescue
    e -> {:error, {cmd, Exception.message(e)}}
  end
end
