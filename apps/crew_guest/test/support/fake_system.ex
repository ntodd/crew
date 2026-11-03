defmodule CrewGuest.FakeSystem do
  @moduledoc """
  A `CrewGuest.System` for tests. Each call is sent to the pid in
  `Application.get_env(:crew_guest, :fake_system)` as `{:system, name}`,
  and steps listed in `:fake_system_fail` return an error. Files and the
  runner command go through `CrewGuest.System.Local`, so the stub runner
  really runs.
  """

  @behaviour CrewGuest.System

  alias CrewGuest.System.Local

  @impl true
  def setup_network(_cfg), do: record(:setup_network)

  @impl true
  def resize_root(_cfg), do: record(:resize_root)

  @impl true
  def install_ca(_cfg, pem), do: record({:install_ca, pem})

  @impl true
  def configure_docker(_cfg, _pem), do: record(:configure_docker)

  @impl true
  def notify_ready(_cfg), do: record(:notify_ready)

  @impl true
  def start_docker(_cfg), do: record(:start_docker)

  @impl true
  def prepare_runner(cfg, files) do
    with :ok <- record({:prepare_runner, Enum.map(files, &elem(&1, 0))}) do
      Local.prepare_runner(cfg, files)
    end
  end

  @impl true
  def runner_command(cfg), do: Local.runner_command(cfg)

  @impl true
  def poweroff(_cfg) do
    record(:poweroff)
    :ok
  end

  defp record(call) do
    if pid = Application.get_env(:crew_guest, :fake_system), do: send(pid, {:system, call})
    name = if is_tuple(call), do: elem(call, 0), else: call

    if name in Application.get_env(:crew_guest, :fake_system_fail, []),
      do: {:error, :injected},
      else: :ok
  end
end
