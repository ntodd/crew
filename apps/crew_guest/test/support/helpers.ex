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
