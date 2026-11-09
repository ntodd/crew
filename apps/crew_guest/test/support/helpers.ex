defmodule CrewGuest.TestHelpers do
  @moduledoc "Helpers shared by crew_guest's tests."

  import ExUnit.Assertions

  @doc "Retries `fun` until it returns a truthy value, or flunks after `timeout` ms."
  def eventually(fun, timeout \\ 5_000, interval \\ 25) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(interval)
          do_eventually(fun, deadline, interval)
        end
    end
  end

  def fixture(name), do: Path.expand("../fixtures/#{name}", __DIR__)

  @doc """
  The pid of the stub runner's listener (its child in its own process
  group, as run.sh's is), once it's up. Its group is killed when the test
  ends, whatever happened.
  """
  def stub_listener(runner_dir) do
    file = Path.join(runner_dir, "listener.pid")
    pid = eventually(fn -> File.exists?(file) && String.trim(File.read!(file)) end)

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-KILL", "--", "-" <> pid], stderr_to_stdout: true)
    end)

    pid
  end

  @doc "The stub runner's last page, where it notes the signals it gets."
  def stub_page(runner_dir) do
    case Path.wildcard(Path.join(runner_dir, "_diag/pages/*_2.log")) do
      [file] -> File.read!(file)
      [] -> ""
    end
  end

  @doc "Whether an OS process is running. A zombie still answers `kill -0`, so this asks ps."
  def os_alive?(os_pid) do
    {out, _} = System.cmd("ps", ["-o", "stat=", "-p", os_pid])
    out = String.trim(out)
    out != "" and not String.starts_with?(out, "Z")
  end

  @doc "An encoded JIT config, shaped like GitHub's `encoded_jit_config`."
  def jit_config(runner_settings \\ %{"DisableUpdate" => true}) do
    runner =
      Map.merge(
        %{
          "AgentId" => 42,
          "AgentName" => "crew-ab12-box-0001",
          "PoolId" => 1,
          "Ephemeral" => true
        },
        runner_settings
      )

    %{
      ".runner" => Base.encode64(Jason.encode!(runner)),
      ".credentials" => Base.encode64(~s({"Scheme":"OAuthAccessToken"})),
      ".credentials_rsaparams" => Base.encode64("{}")
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  def payload(overrides \\ %{}) do
    Map.merge(
      %{
        "jit_config" => jit_config(),
        "ca_pem" => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
        "policy" => %{"fork_prs" => "refuse", "repo_full_name" => "ntodd/crew"},
        "size" => %{"vcpus" => 2, "memory_mib" => 4096, "disk_gib" => 20},
        "labels" => ["crew-m"]
      },
      overrides
    )
  end

  @doc """
  Records when the client starts each request to `api`, as Finch reports
  it, for `request_starts/1`. That's the moment the Outbox paces, and,
  unlike `at` at the server, it doesn't move when the first request's
  connect and upload are slow.
  """
  def record_request_starts(api) do
    id = {__MODULE__, make_ref()}
    config = %{port: CrewGuest.FakeAPI.port(api), to: self()}
    :telemetry.attach(id, [:finch, :request, :start], &__MODULE__.forward_request_start/4, config)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def forward_request_start(_event, _measurements, %{request: req}, %{port: port, to: to}) do
    if req.port == port,
      do: send(to, {:request_start, req.path, System.monotonic_time(:millisecond)})
  end

  @doc """
  The monotonic ms at which the client started each request to `path`,
  oldest first. Each request reports from its own process, so they're
  sorted rather than taken in mailbox order.
  """
  def request_starts(path), do: path |> drain_request_starts() |> Enum.sort()

  defp drain_request_starts(path) do
    receive do
      {:request_start, ^path, at} -> [at | drain_request_starts(path)]
    after
      0 -> []
    end
  end

  @doc "Starts a client for `api` that reports stop requests to the test process."
  def client(api, opts \\ []) do
    test = self()

    CrewGuest.API.new(
      Keyword.merge(
        [
          base_url: CrewGuest.FakeAPI.url(api),
          token: "t0ken",
          on_stop: fn -> send(test, :stop_requested) end
        ],
        opts
      )
    )
  end
end
