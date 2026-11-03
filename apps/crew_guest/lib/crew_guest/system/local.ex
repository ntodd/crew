defmodule CrewGuest.System.Local do
  @moduledoc """
  The null driver's `CrewGuest.System` (§11.5): crew-guest as a plain
  process, without root, on Linux or macOS. DNS, IPv6, the disk and Docker
  are left alone; the CA is only kept in the run dir; the runner runs as
  the current user; and "powering off" exits crew-guest cleanly.
  """

  @behaviour CrewGuest.System

  @impl true
  def setup_network(_cfg), do: :ok

  @impl true
  def resize_root(_cfg), do: :ok

  @impl true
  def install_ca(cfg, pem) do
    with :ok <- File.mkdir_p(cfg.run_dir) do
      File.write(Path.join(cfg.run_dir, "crew-cache.crt"), pem)
    end
  end

  @impl true
  def configure_docker(_cfg, _pem), do: :ok

  @impl true
  def notify_ready(_cfg) do
    _ = CrewGuest.Systemd.notify("READY=1")
    :ok
  end

  @impl true
  def start_docker(_cfg), do: :ok

  @impl true
  def prepare_runner(cfg, files) do
    with :ok <- CrewGuest.System.write_run_files(cfg.run_dir, files) do
      File.mkdir_p(Path.join(cfg.runner_dir, "_diag/pages"))
    end
  end

  @impl true
  def runner_command(cfg), do: cfg.runner_cmd

  @impl true
  def poweroff(_cfg) do
    System.stop(0)
    :ok
  end
end
