defmodule CrewAgent.Driver.VZ.Upgrade do
  @moduledoc """
  crew-vzd's half of an update on macOS (§20.2). launchd runs crew-vzd
  from the agent's release (`agent/current/bin/crew-vz`), and crew-vzd
  keeps the release it started from (it resolves its own path). After an
  update moves `current`, the agent asks it to restart, which crew-vzd
  only does once no VM runs; until then the old crew-vzd keeps serving,
  and its release isn't pruned (`CrewAgent.Updater.keep/1`).

  Checked every 30 s, and once per version: a crew-vzd that comes back
  on another version than `current`'s (run from elsewhere, as in
  development) isn't asked again.
  """
  use GenServer

  alias CrewAgent.{Config, Updater, VMs}
  alias CrewAgent.Driver.VZ.Daemon

  require Logger

  @every 30_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.send_after(self(), :check, 10_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    check(Config.get())
    Process.send_after(self(), :check, @every)
    {:noreply, state}
  end

  @doc "crew-vzd's version, or nil when it doesn't answer."
  @spec vzd_version(Config.t()) :: String.t() | nil
  def vzd_version(%Config{} = config) do
    case Daemon.request(socket(config), %{"op" => "version"}) do
      {:ok, %{"version" => version}} when is_binary(version) -> version
      _ -> nil
    end
  end

  @doc """
  Asks crew-vzd to restart onto `current`'s release if it's on another
  and no VM runs. `:busy` while VMs run, `:restarted` when it was asked.
  """
  @spec check(Config.t(), keyword()) :: :ok | :busy | :restarted
  def check(%Config{} = config, opts \\ []) do
    running = Keyword.get(opts, :running, &VMs.running_count/0)
    memo = Keyword.get(opts, :memo, __MODULE__)
    current = Updater.current_version(Config.agent_dir(config))

    with true <- is_binary(current),
         true <- File.regular?(Path.join([Config.agent_dir(config), current, "bin/crew-vz"])),
         true <- :persistent_term.get(memo, nil) != current,
         vzd when is_binary(vzd) and vzd != current <- vzd_version(config) do
      restart(config, running.(), current, vzd, memo)
    else
      _ -> :ok
    end
  end

  defp restart(_config, n, _current, _vzd, _memo) when n > 0, do: :busy

  defp restart(config, 0, current, vzd, memo) do
    case Daemon.request(socket(config), %{"op" => "restart"}) do
      {:ok, _} ->
        Logger.info("asked crew-vzd #{vzd} to restart onto #{current}")
        :persistent_term.put(memo, current)
        :restarted

      {:error, "busy", _} ->
        :busy

      {:error, code, detail} ->
        Logger.warning("crew-vzd wouldn't restart onto #{current}: #{code} #{detail}")
        :ok
    end
  end

  defp socket(config), do: config.vzd_socket || Path.join(config.data_dir, "vzd.sock")
end
