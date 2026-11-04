defmodule CrewGuest.Config do
  @moduledoc """
  crew-guest's settings.

  In a job VM they come from the kernel command line (§13.3):
  `crew.vm=<vm_id> crew.token=<token> crew.api=<url>`. Environment
  variables override them, which is how the dev-only null driver (§11.5)
  runs crew-guest as a local process:

  | Variable | Default |
  |---|---|
  | `CREW_GUEST_MODE` | `vm`, or `local` (no root-only steps; poweroff exits) |
  | `CREW_GUEST_VM`, `CREW_GUEST_TOKEN`, `CREW_GUEST_API` | `crew.vm`, `crew.token`, `crew.api` |
  | `CREW_GUEST_RUNNER_DIR` | `/home/runner/actions-runner` |
  | `CREW_GUEST_RUNNER_CMD` | `<runner_dir>/run.sh` (split like a shell would; `--jitconfig` is appended) |
  | `CREW_GUEST_RUN_DIR` | `/run/crew` in `vm` mode, `<runner_dir>/.crew` in `local` mode |

  In `vm` mode the runner runs as the user `runner`; in `local` mode, as
  whoever runs crew-guest.
  """

  @derive {Inspect, except: [:token]}
  @enforce_keys [:mode, :vm_id, :token, :api_url, :runner_dir, :runner_cmd, :run_dir]
  defstruct [
    :mode,
    :vm_id,
    :token,
    :api_url,
    :runner_dir,
    :runner_cmd,
    :run_dir,
    runner_user: nil,
    # Extra environment for the runner. Tests use it to drive the stub.
    runner_env: [],
    payload_timeout_ms: 60_000,
    payload_retry_ms: 200,
    # A stop the agent asks for: the runner gets half, the flush the rest.
    flush_timeout_ms: 10_000,
    # The same for SIGTERM, which systemd follows with SIGKILL after the
    # unit's stop timeout.
    sigterm_timeout_ms: 6_000,
    metrics_interval_ms: 5_000
  ]

  @type t :: %__MODULE__{}

  @default_runner_dir "/home/runner/actions-runner"

  @doc """
  Loads the settings. Options (for tests): `:cmdline`, the kernel command
  line (`nil` when there's none), and `:env`, a map of environment
  variables. By default both are read from the system.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with {:ok, mode} <- mode(env["CREW_GUEST_MODE"]) do
      cmdline =
        Keyword.get_lazy(opts, :cmdline, fn -> if mode == :vm, do: read_cmdline() end)

      build(mode, parse_cmdline(cmdline), env)
    end
  end

  @doc "Parses `crew.*` arguments from a kernel command line."
  @spec parse_cmdline(String.t() | nil) :: %{String.t() => String.t()}
  def parse_cmdline(nil), do: %{}

  def parse_cmdline(cmdline) do
    for arg <- String.split(cmdline),
        [key, value] <- [String.split(arg, "=", parts: 2)],
        String.starts_with?(key, "crew."),
        into: %{},
        do: {key, value}
  end

  defp build(mode, args, env) do
    values = %{
      "crew.vm" => present(env["CREW_GUEST_VM"]) || args["crew.vm"],
      "crew.token" => present(env["CREW_GUEST_TOKEN"]) || args["crew.token"],
      "crew.api" => present(env["CREW_GUEST_API"]) || args["crew.api"]
    }

    missing = for {k, v} <- values, v in [nil, ""], do: k

    with [] <- missing,
         {:ok, api_url} <- api_url(values["crew.api"]) do
      runner_dir = present(env["CREW_GUEST_RUNNER_DIR"]) || @default_runner_dir

      {:ok,
       %__MODULE__{
         mode: mode,
         vm_id: values["crew.vm"],
         token: values["crew.token"],
         api_url: api_url,
         runner_dir: runner_dir,
         runner_cmd: runner_cmd(env["CREW_GUEST_RUNNER_CMD"], runner_dir),
         run_dir: present(env["CREW_GUEST_RUN_DIR"]) || default_run_dir(mode, runner_dir),
         runner_user: if(mode == :vm, do: "runner")
       }}
    else
      [_ | _] -> {:error, {:missing, Enum.sort(missing)}}
      {:error, _} = error -> error
    end
  end

  defp mode(nil), do: {:ok, :vm}
  defp mode("vm"), do: {:ok, :vm}
  defp mode("local"), do: {:ok, :local}
  defp mode(other), do: {:error, {:bad_mode, other}}

  defp api_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        {:error, {:bad_api_url, url}}
    end
  end

  defp runner_cmd(cmd, runner_dir) do
    case present(cmd) do
      nil -> [Path.join(runner_dir, "run.sh")]
      cmd -> OptionParser.split(cmd)
    end
  end

  defp default_run_dir(:vm, _runner_dir), do: "/run/crew"
  defp default_run_dir(:local, runner_dir), do: Path.join(runner_dir, ".crew")

  defp read_cmdline do
    case File.read("/proc/cmdline") do
      {:ok, cmdline} -> cmdline
      {:error, _} -> nil
    end
  end

  defp present(nil), do: nil
  defp present(value), do: if(String.trim(value) == "", do: nil, else: value)
end
