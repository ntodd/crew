defmodule CrewGuest.ConfigTest do
  use ExUnit.Case, async: true

  alias CrewGuest.Config

  @vm_id "0190f0a2-7b1c-7d2e-8f3a-1b2c3d4e5f60"
  @cmdline "console=ttyS0 reboot=k panic=1 pci=off quiet loglevel=4 root=/dev/vda rw " <>
             "rootfstype=ext4 ip=10.200.0.2::10.200.0.1:255.255.255.252::eth0:off " <>
             "crew.vm=#{@vm_id} crew.token=s3cret crew.api=http://10.199.0.1:7777\n"

  test "vm mode reads crew.* from the kernel command line" do
    assert {:ok, cfg} = Config.load(cmdline: @cmdline, env: %{})
    assert cfg.mode == :vm
    assert cfg.vm_id == @vm_id
    assert cfg.token == "s3cret"
    assert cfg.api_url == "http://10.199.0.1:7777"
    assert cfg.runner_dir == "/home/runner/actions-runner"
    assert cfg.run_dir == "/run/crew"
    assert cfg.runner_user == "runner"
    assert cfg.runner_cmd == ["/home/runner/actions-runner/run.sh"]
  end

  test "env vars override the command line" do
    env = %{
      "CREW_GUEST_VM" => "other-vm",
      "CREW_GUEST_TOKEN" => "env-token",
      "CREW_GUEST_API" => "http://127.0.0.1:4000/",
      "CREW_GUEST_RUNNER_DIR" => "/srv/runner"
    }

    assert {:ok, cfg} = Config.load(cmdline: @cmdline, env: env)
    assert cfg.vm_id == "other-vm"
    assert cfg.token == "env-token"
    # A trailing slash is dropped so paths join cleanly.
    assert cfg.api_url == "http://127.0.0.1:4000"
    assert cfg.runner_cmd == ["/srv/runner/run.sh"]
  end

  test "local mode needs no command line, and runs the runner as the current user" do
    env = %{
      "CREW_GUEST_MODE" => "local",
      "CREW_GUEST_VM" => @vm_id,
      "CREW_GUEST_TOKEN" => "t",
      "CREW_GUEST_API" => "http://127.0.0.1:7777",
      "CREW_GUEST_RUNNER_DIR" => "/tmp/vm1/runner"
    }

    assert {:ok, cfg} = Config.load(cmdline: nil, env: env)
    assert cfg.mode == :local
    assert cfg.runner_user == nil
    assert cfg.run_dir == "/tmp/vm1/runner/.crew"
  end

  test "CREW_GUEST_RUN_DIR and CREW_GUEST_RUNNER_CMD override their defaults" do
    env = %{
      "CREW_GUEST_RUN_DIR" => "/tmp/run",
      "CREW_GUEST_RUNNER_CMD" => ~s(/opt/stub/stub-runner --name "two words")
    }

    assert {:ok, cfg} = Config.load(cmdline: @cmdline, env: env)
    assert cfg.run_dir == "/tmp/run"
    assert cfg.runner_cmd == ["/opt/stub/stub-runner", "--name", "two words"]
  end

  test "missing values are an error that names them" do
    assert {:error, {:missing, missing}} = Config.load(cmdline: "quiet", env: %{})
    assert Enum.sort(missing) == ["crew.api", "crew.token", "crew.vm"]

    assert {:error, {:missing, ["crew.token"]}} =
             Config.load(
               cmdline: nil,
               env: %{
                 "CREW_GUEST_MODE" => "local",
                 "CREW_GUEST_VM" => "v",
                 "CREW_GUEST_API" => "http://x:1"
               }
             )
  end

  test "an API URL that isn't http(s) is refused" do
    env = %{"CREW_GUEST_API" => "file:///etc/passwd"}
    assert {:error, {:bad_api_url, _}} = Config.load(cmdline: @cmdline, env: env)
  end

  test "an unknown mode is refused" do
    assert {:error, {:bad_mode, "metal"}} =
             Config.load(cmdline: @cmdline, env: %{"CREW_GUEST_MODE" => "metal"})
  end

  test "the token never shows up in inspect output" do
    {:ok, cfg} = Config.load(cmdline: @cmdline, env: %{})
    refute inspect(cfg) =~ "s3cret"
  end
end
