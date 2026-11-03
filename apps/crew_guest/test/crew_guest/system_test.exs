defmodule CrewGuest.SystemTest do
  use ExUnit.Case, async: true

  alias CrewGuest.Config
  alias CrewGuest.System.{Linux, Local}

  @moduletag :tmp_dir

  @pem "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  @files [
    {"policy.json", ~s({"fork_prs":"refuse"}), :public},
    {"jit", "the-jit", :private},
    {"guest.env", "CREW_TOKEN='t'\n", :private}
  ]

  defp config(mode, runner_dir, run_dir) do
    %Config{
      mode: mode,
      vm_id: "vm",
      token: "t",
      api_url: "http://10.199.0.1:7777",
      runner_dir: runner_dir,
      run_dir: run_dir,
      runner_cmd: [Path.join(runner_dir, "run.sh")],
      runner_user: if(mode == :vm, do: "runner")
    }
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "impl/1 picks the implementation for the mode" do
    assert CrewGuest.System.impl(:vm) == Linux
    assert CrewGuest.System.impl(:local) == Local
  end

  describe "Local" do
    setup %{tmp_dir: dir} do
      %{cfg: config(:local, Path.join(dir, "runner"), Path.join(dir, "run"))}
    end

    test "writes the run files, the private ones 0600, and makes the pages dir",
         %{cfg: cfg} do
      assert :ok = Local.prepare_runner(cfg, @files)
      assert File.read!(Path.join(cfg.run_dir, "jit")) == "the-jit"
      assert mode(Path.join(cfg.run_dir, "jit")) == 0o600
      assert mode(Path.join(cfg.run_dir, "guest.env")) == 0o600
      assert mode(Path.join(cfg.run_dir, "policy.json")) == 0o644
      assert File.dir?(Path.join(cfg.runner_dir, "_diag/pages"))
    end

    test "keeps the CA in the run dir, and skips the root-only steps", %{cfg: cfg} do
      assert :ok = Local.install_ca(cfg, @pem)
      assert File.read!(Path.join(cfg.run_dir, "crew-cache.crt")) == @pem

      for step <- [:setup_network, :resize_root, :start_docker, :notify_ready] do
        assert :ok = apply(Local, step, [cfg])
      end

      assert :ok = Local.configure_docker(cfg, @pem)
    end

    test "runs the configured command as the current user", %{cfg: cfg} do
      assert Local.runner_command(cfg) == cfg.runner_cmd
    end
  end

  describe "Linux" do
    setup %{tmp_dir: root} do
      test = self()

      run = fn cmd, args ->
        send(test, {:run, cmd, args})
        if Process.get({:fail, cmd, args}), do: {:error, :failed}, else: :ok
      end

      runner_dir = "/home/runner/actions-runner"
      File.mkdir_p!(Path.join(root, runner_dir))
      File.mkdir_p!(Path.join(root, "etc"))
      File.mkdir_p!(Path.join(root, "proc/sys/net/ipv6/conf/eth0"))
      File.write!(Path.join(root, "etc/environment"), ~s(PATH="/usr/local/bin:/usr/bin:/bin"\n))

      File.write!(
        Path.join(root, runner_dir <> "/.env"),
        "LANG=C.UTF-8\nACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/crew/hooks/job-started\n"
      )

      # Ubuntu's resolv.conf is a symlink to systemd-resolved's stub.
      File.ln_s!("../run/systemd/resolve/stub-resolv.conf", Path.join(root, "etc/resolv.conf"))

      %{
        root: root,
        opts: [root: root, run: run],
        cfg: config(:vm, runner_dir, "/run/crew")
      }
    end

    test "points DNS at the box and turns IPv6 off on eth0", %{cfg: cfg, root: root, opts: opts} do
      assert :ok = Linux.setup_network(cfg, opts)

      resolv = Path.join(root, "etc/resolv.conf")
      assert {:ok, %{type: :regular}} = File.lstat(resolv)
      assert File.read!(resolv) == "nameserver 10.199.0.1\n"
      assert File.read!(Path.join(root, "proc/sys/net/ipv6/conf/eth0/disable_ipv6")) == "1"
    end

    test "grows the root filesystem", %{cfg: cfg, opts: opts} do
      assert :ok = Linux.resize_root(cfg, opts)
      assert_received {:run, "resize2fs", ["/dev/vda"]}
    end

    test "installs the cache CA and points every client at it",
         %{cfg: cfg, root: root, opts: opts} do
      assert :ok = Linux.install_ca(cfg, @pem, opts)
      assert :ok = Linux.install_ca(cfg, @pem, opts)

      crt = Path.join(root, "usr/local/share/ca-certificates/crew-cache.crt")
      assert File.read!(crt) == @pem
      assert_received {:run, "update-ca-certificates", []}

      vars = [
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
        "NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/crew-cache.crt",
        "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
        "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
      ]

      environment = File.read!(Path.join(root, "etc/environment"))
      assert environment =~ ~s(PATH="/usr/local/bin:/usr/bin:/bin")
      for var <- vars, do: assert(count(environment, var) == 1, var)

      profile = File.read!(Path.join(root, "etc/profile.d/crew-ca.sh"))
      for var <- vars, do: assert(profile =~ "export " <> var)

      env = File.read!(Path.join(root, cfg.runner_dir <> "/.env"))
      assert env =~ "ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/crew/hooks/job-started"
      for var <- vars, do: assert(count(env, var) == 1, var)
    end

    test "configures Docker and BuildKit", %{cfg: cfg, root: root, opts: opts} do
      File.mkdir_p!(Path.join(root, "etc/docker"))
      File.write!(Path.join(root, "etc/docker/daemon.json"), ~s({"features": {"buildkit": true}}))

      assert :ok = Linux.configure_docker(cfg, @pem, opts)

      daemon = root |> Path.join("etc/docker/daemon.json") |> File.read!() |> Jason.decode!()
      assert daemon == %{"log-driver" => "local", "features" => %{"buildkit" => true}}

      toml = File.read!(Path.join(root, "etc/buildkit/buildkitd.toml"))

      for host <- ["docker.io", "ghcr.io", "public.ecr.aws", "10.199.0.1"] do
        assert toml =~
                 ~s([registry."#{host}"]\n  ca = ["/usr/local/share/ca-certificates/crew-cache.crt"])
      end
    end

    test "starts containerd and Docker", %{cfg: cfg, opts: opts} do
      assert :ok = Linux.start_docker(cfg, opts)
      assert_received {:run, "systemctl", ["start", "containerd.service", "docker.service"]}
    end

    test "hands the private files and _diag to the runner user",
         %{cfg: cfg, root: root, opts: opts} do
      assert :ok = Linux.prepare_runner(cfg, @files, opts)

      jit = Path.join(root, "run/crew/jit")
      assert File.read!(jit) == "the-jit"
      assert mode(jit) == 0o600
      assert mode(Path.join(root, "run/crew/policy.json")) == 0o644
      assert File.dir?(Path.join(root, cfg.runner_dir <> "/_diag/pages"))

      assert_received {:run, "chown", ["runner:runner", ^jit]}
      assert_received {:run, "chown", ["runner:runner", _guest_env]}
      assert_received {:run, "chown", ["-R", "runner:runner", diag]}
      assert diag == Path.join(root, cfg.runner_dir <> "/_diag")
    end

    test "runs the runner as the runner user with a clean environment", %{cfg: cfg} do
      assert Linux.runner_command(cfg) == [
               "setpriv",
               "--reuid=runner",
               "--regid=runner",
               "--init-groups",
               "--reset-env",
               "--",
               "env",
               "RUNNER_MANUALLY_TRAP_SIG=1",
               "/home/runner/actions-runner/run.sh"
             ]
    end

    test "powers off through systemd, forcing it if that fails", %{cfg: cfg, opts: opts} do
      Process.put({:fail, "systemctl", ["poweroff"]}, true)
      assert :ok = Linux.poweroff(cfg, opts)
      assert_received {:run, "systemctl", ["poweroff"]}
      assert_received {:run, "systemctl", ["poweroff", "--force"]}
    end
  end

  defp count(text, needle), do: length(String.split(text, needle)) - 1
end
