defmodule CrewAgent.Updater.RootStepTest do
  @moduledoc """
  The agent's half of a Linux update's root step (§10.8, §20.2): the
  request it stages for crew-root-install, and how it waits for root's
  answer. Root's half, `priv/flatcar/root-install.sh`, is run for real by
  the control plane's tests (`Crew.Boxes.FlatcarRootInstallTest`), against
  the same request format.
  """
  use ExUnit.Case, async: true

  alias CrewAgent.Config
  alias CrewAgent.Updater.RootStep

  setup do
    data = Path.join(System.tmp_dir!(), "crew-root-step-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data) end)
    stage = Path.join(data, "agent/update")
    File.mkdir_p!(stage)
    File.mkdir_p!(Path.join(data, "root"))
    File.write!(Path.join(stage, "agent.tar.gz"), "agent")
    File.write!(Path.join(stage, "cache.tar.gz"), "cache")

    staged = %{
      version: "0.2.0",
      target: "linux-arm64",
      agent: %{
        path: Path.join(stage, "agent.tar.gz"),
        sha256: String.duplicate("a", 64),
        signature: "c2lnbmF0dXJl"
      },
      cache: %{
        path: Path.join(stage, "cache.tar.gz"),
        sha256: String.duplicate("b", 64),
        signature: "Y2FjaGUtc2ln"
      }
    }

    %{config: %Config{driver: "firecracker", data_dir: data}, data: data, staged: staged}
  end

  # Root, as crew-root-install would be: waits for the request, takes it,
  # and answers in root/update.result.
  defp fake_root(ctx, answer) do
    test = self()
    request = Path.join(ctx.data, "agent/update/request")
    result = Path.join(ctx.data, "root/update.result")

    Task.start_link(fn ->
      body = wait_for(request)
      File.rm!(request)
      fields = parse(body)
      send(test, {:request, body, fields})

      case answer.(fields) do
        nil ->
          :ok

        lines ->
          File.write!(result <> ".tmp", lines)
          File.rename!(result <> ".tmp", result)
      end
    end)
  end

  defp wait_for(path) do
    case File.read(path) do
      {:ok, body} ->
        body

      {:error, _} ->
        Process.sleep(5)
        wait_for(path)
    end
  end

  defp parse(body) do
    for line <- String.split(body, "\n", trim: true), into: %{} do
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end
  end

  test "stages the request root checks the tarballs against, and waits for root's ok", ctx do
    fake_root(ctx, fn f ->
      File.ln_s!(f["VERSION"], Path.join(ctx.data, "root/current"))
      "ok #{f["NONCE"]} #{f["VERSION"]}\n"
    end)

    assert :ok = RootStep.install(ctx.config, ctx.staged, poll_ms: 5)
    assert_received {:request, body, fields}

    assert Map.keys(fields) |> Enum.sort() ==
             ~w(AGENT_SHA256 AGENT_SIG CACHE_SHA256 CACHE_SIG NONCE TARGET VERSION)

    assert fields["NONCE"] =~ ~r/\A[0-9a-f]{32}\z/
    assert fields["VERSION"] == "0.2.0"
    assert fields["TARGET"] == "linux-arm64"
    assert fields["AGENT_SHA256"] == String.duplicate("a", 64)
    assert fields["AGENT_SIG"] == "c2lnbmF0dXJl"
    assert fields["CACHE_SHA256"] == String.duplicate("b", 64)
    assert fields["CACHE_SIG"] == "Y2FjaGUtc2ln"
    assert String.ends_with?(body, "\n")
  end

  test "root's refusal is the update's", ctx do
    fake_root(ctx, fn f -> "error #{f["NONCE"]} the agent's signature doesn't verify\n" end)

    assert {:error, "the agent's signature doesn't verify"} =
             RootStep.install(ctx.config, ctx.staged, poll_ms: 5)
  end

  test "an answer to another request isn't this one's", ctx do
    File.write!(Path.join(ctx.data, "root/update.result"), "ok 0123 0.2.0\n")
    fake_root(ctx, fn _f -> nil end)

    assert {:error, message} =
             RootStep.install(ctx.config, ctx.staged, poll_ms: 5, timeout_ms: 200)

    assert message =~ "crew-root-install didn't answer"
  end

  test "an ok that didn't move root/current isn't one", ctx do
    fake_root(ctx, fn f -> "ok #{f["NONCE"]} #{f["VERSION"]}\n" end)

    assert {:error, message} = RootStep.install(ctx.config, ctx.staged, poll_ms: 5)
    assert message =~ "root/current"
  end

  test "the tarballs must be the staged ones", ctx do
    staged = put_in(ctx.staged.agent.path, "/tmp/elsewhere.tar.gz").staged
    assert {:error, message} = RootStep.install(ctx.config, staged, poll_ms: 5, timeout_ms: 50)
    assert message =~ "staged"
    refute File.exists?(Path.join(ctx.data, "agent/update/request"))
  end
end
