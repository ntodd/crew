defmodule CrewGuest.System do
  @moduledoc """
  Every step that touches the OS (§13.5), behind one behaviour:
  - `CrewGuest.System.Linux` is the job VM's;
  - `CrewGuest.System.Local` is the null driver's (§11.5): it skips what
    needs root and "powers off" by exiting;
  - tests use a fake.

  `prepare_runner/2` gets `{name, contents, :private | :public}` files for
  the run dir: private ones are 0600 and belong to the runner's user.
  """

  alias CrewGuest.Config

  @type result :: :ok | {:error, term()}
  @type file :: {String.t(), iodata(), :private | :public}

  @doc "Writes `/etc/resolv.conf` and disables IPv6 on `eth0` (§13.2)."
  @callback setup_network(Config.t()) :: result()

  @doc "Grows the root filesystem to the disk. Runs in the background; Docker waits for it."
  @callback resize_root(Config.t()) :: result()

  @doc "Trusts the cache CA system-wide and in the runner's environment (§15.4)."
  @callback install_ca(Config.t(), pem :: String.t()) :: result()

  @doc "Writes Docker's and BuildKit's config."
  @callback configure_docker(Config.t(), pem :: String.t() | nil, mirrors :: [String.t()]) ::
              result()

  @doc "Tells systemd crew-guest is ready, which lets the units ordered after it start."
  @callback notify_ready(Config.t()) :: result()

  @doc "Starts containerd and Docker."
  @callback start_docker(Config.t()) :: result()

  @doc "Writes the run dir's files and makes the runner's `_diag/pages`."
  @callback prepare_runner(Config.t(), [file()]) :: result()

  @doc "The command that runs the runner (`--jitconfig` is appended to it)."
  @callback runner_command(Config.t()) :: [String.t()]

  @doc "Powers the VM off. In local mode, exits."
  @callback poweroff(Config.t()) :: :ok

  @doc """
  Ends crew-guest after a SIGTERM. Whoever sent it (systemd, on its way to
  `poweroff.target`) is already stopping the VM, so this only exits.
  """
  @callback stop(Config.t()) :: :ok

  @spec impl(:vm | :local) :: module()
  def impl(:vm), do: CrewGuest.System.Linux
  def impl(:local), do: CrewGuest.System.Local

  @doc false
  # Shared by the implementations: writes the run dir's files.
  def write_run_files(run_dir, files, after_write \\ fn _path, _kind -> :ok end) do
    with :ok <- File.mkdir_p(run_dir) do
      Enum.reduce_while(files, :ok, fn {name, contents, kind}, :ok ->
        path = Path.join(run_dir, name)
        mode = if kind == :private, do: 0o600, else: 0o644

        with :ok <- write_new(path, contents, mode),
             :ok <- after_write.(path, kind) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  # The mode is set before the contents go in, so a secret is never
  # readable by anyone else, even for a moment.
  defp write_new(path, contents, mode) do
    with :ok <- File.write(path, ""),
         :ok <- File.chmod(path, mode) do
      File.write(path, contents)
    end
  end
end
