defmodule Crew.Agents.UpdatesTest do
  @moduledoc """
  Agent updates on the control plane (§20.2, Foreman's): each box's
  target version, `agent.update` on join, its outcome (the version the
  box comes back on, the agent's result, a rollback), the two-failures
  rule, and an admin's pin. The test process stands in for the box's
  agent, so commands arrive as `{:dispatch, cmd}`.
  """
  use Crew.DataCase

  import Crew.AgentReleaseFixtures
  import Crew.Fixtures

  alias Crew.Agents.{Releases, Updates}
  alias Crew.Boxes
  alias Crew.Operations
  alias Crew.Operations.Operation
  alias Crew.{ImageFixtures, Scope}
  alias CrewProtocol.Command

  setup do
    key = ImageFixtures.keypair()
    ImageFixtures.trust(key)
    dir = tmp_dir("agent-updates")
    %{key: key, dir: dir, admin: Scope.for_user(user_fixture(role: "admin"))}
  end

  defp register(ctx, version, target, opts \\ []) do
    write_release(ctx.dir, ctx.key, version, target, opts)
    Releases.register_bundle(ctx.dir)
  end

  defp linux_box(attrs \\ []) do
    box_fixture(
      Keyword.merge([type: "linux-vm", capabilities: capabilities(driver: "firecracker")], attrs)
    )
    |> Ecto.Changeset.change(
      os: "linux",
      arch: "arm64",
      agent_version: attrs[:agent_version] || "0.1.0"
    )
    |> Repo.update!()
  end

  defp mac_box do
    box_fixture()
    |> Ecto.Changeset.change(os: "darwin", arch: "arm64", agent_version: "0.1.0")
    |> Repo.update!()
  end

  defp online(box) do
    {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})
    box
  end

  defp rejoin(box, version, in_flight \\ []) do
    box = box |> Repo.reload!() |> Ecto.Changeset.change(agent_version: version) |> Repo.update!()
    Updates.joined(box, %{agent_version: version, in_flight: in_flight})
    Repo.reload!(box)
  end

  defp update_command(timeout \\ 500) do
    assert_receive {:dispatch, %Command{type: "agent.update"} = cmd}, timeout
    cmd
  end

  defp result(box, cmd, payload) do
    :ok = Operations.record_result(box.id, Map.put(payload, :op_id, cmd.op_id))
    Operations.get!(cmd.op_id)
  end

  defp ok(box, cmd, version),
    do:
      result(box, cmd, %{
        status: "ok",
        result: %{"version" => version, "restart" => true, "from" => "0.1.0"}
      })

  defp failed(box, cmd, code \\ "download_failed"),
    do: result(box, cmd, %{status: "error", error: %{code: code, message: "it failed"}})

  defp age(op, field, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds)

    case field do
      :restart_reported_at ->
        op
        |> Ecto.Changeset.change(
          args: Map.put(op.args, "restart_reported_at", DateTime.to_iso8601(at))
        )
        |> Repo.update!()

      :dispatched_at ->
        op |> Ecto.Changeset.change(dispatched_at: at) |> Repo.update!()
    end
  end

  describe "the version a box should run" do
    test "is the newest registered for its target, with crew_cache too on Linux", ctx do
      register(ctx, "0.2.0", "linux-arm64")
      register(ctx, "0.3.0", "linux-arm64", components: ["agent"])
      register(ctx, "0.4.0-rc.1", "linux-arm64")
      register(ctx, "0.5.0", "darwin-arm64", components: ["agent"])

      assert Releases.fleet_version("linux-arm64") == "0.2.0"
      assert Releases.fleet_version("darwin-arm64") == "0.5.0"
      assert Releases.fleet_version("linux-amd64") == nil

      assert Updates.target_version(linux_box()) == "0.2.0"
      assert Updates.target_version(mac_box()) == "0.5.0"
    end

    test "is the pinned version when there is one", ctx do
      register(ctx, "0.2.0", "linux-arm64")
      register(ctx, "0.3.0", "linux-arm64")
      box = linux_box() |> Ecto.Changeset.change(desired_agent_version: "0.2.0") |> Repo.update!()
      assert Updates.target_version(box) == "0.2.0"
    end

    test "is nothing for a box that hasn't said what it runs on", ctx do
      register(ctx, "0.2.0", "linux-arm64")
      box = linux_box() |> Ecto.Changeset.change(arch: nil) |> Repo.update!()
      assert Updates.target_version(box) == nil
    end
  end

  describe "on join" do
    test "a Linux box behind gets agent.update with both tarballs, from the control plane", ctx do
      register(ctx, "0.2.0", "linux-arm64")
      box = linux_box() |> online()
      rejoin(box, "0.1.0")

      cmd = update_command()
      agent = Releases.get("agent", "0.2.0", "linux-arm64")
      cache = Releases.get("cache", "0.2.0", "linux-arm64")

      assert cmd.payload.version == "0.2.0"
      assert cmd.payload.sha256 == agent.sha256
      assert cmd.payload.size == agent.size
      assert cmd.payload.signature == agent.signature

      assert cmd.payload.url ==
               "#{Crew.Config.base_url()}/agent/releases/0.2.0/linux-arm64/crew-agent-0.2.0-linux-arm64.tar.gz"

      assert cmd.payload.cache.sha256 == cache.sha256
      assert cmd.payload.cache.url =~ "/crew-cache-0.2.0-linux-arm64.tar.gz"

      assert %Operation{
               command: "agent.update",
               status: "dispatched",
               args: %{"version" => "0.2.0"}
             } =
               Operations.get!(cmd.op_id)
    end

    test "a Mac gets only the agent's tarball", ctx do
      register(ctx, "0.2.0", "darwin-arm64", components: ["agent"])
      box = mac_box() |> online()
      rejoin(box, "0.1.0")
      cmd = update_command()
      assert cmd.payload.url =~ "crew-agent-0.2.0-darwin-arm64.tar.gz"
      refute Map.has_key?(cmd.payload, :cache)
    end

    test "nothing goes to a box on its version, with no release, or with an update under way",
         ctx do
      register(ctx, "0.2.0", "linux-arm64")
      box = linux_box() |> online()

      rejoin(box, "0.2.0")
      refute_receive {:dispatch, _}, 50

      mac_box() |> online() |> rejoin("0.1.0")
      refute_receive {:dispatch, _}, 50

      rejoin(box, "0.1.0")
      update_command()
      rejoin(box, "0.1.0", [])
      refute_receive {:dispatch, _}, 50
    end
  end

  describe "an update's outcome" do
    setup ctx do
      register(ctx, "0.2.0", "linux-arm64")
      box = linux_box() |> online()
      rejoin(box, "0.1.0")
      %{box: box, cmd: update_command()}
    end

    test "the agent's report keeps it running until the box comes back on the version", ctx do
      op = ok(ctx.box, ctx.cmd, "0.2.0")
      assert op.status == "running"
      assert op.args["restart_reported_at"]

      rejoin(ctx.box, "0.2.0")
      assert %Operation{status: "succeeded"} = Operations.get!(ctx.cmd.op_id)
      refute_receive {:dispatch, _}, 50
    end

    test "a box that comes back on the version settles it even without the report", ctx do
      rejoin(ctx.box, "0.2.0")
      assert %Operation{status: "succeeded"} = Operations.get!(ctx.cmd.op_id)
    end

    test "a refusal fails it, and it's sent again; twice and the version stops", ctx do
      assert %Operation{status: "failed"} = failed(ctx.box, ctx.cmd, "sha256_mismatch")
      assert Repo.reload!(ctx.box).failed_agent_version == nil

      rejoin(ctx.box, "0.1.0")
      second = update_command()
      failed(ctx.box, second)

      box = Repo.reload!(ctx.box)
      assert box.failed_agent_version == "0.2.0"
      rejoin(box, "0.1.0")
      refute_receive {:dispatch, _}, 50
      assert %{state: :blocked, version: "0.2.0"} = Updates.status(Repo.reload!(box))
    end

    test "a rollback the agent reports after its restart fails it", ctx do
      ok(ctx.box, ctx.cmd, "0.2.0")
      # The release it rolled back to joins and says so.
      rejoin(ctx.box, "0.1.0")

      assert %Operation{status: "failed", error_code: "rolled_back"} =
               failed(ctx.box, ctx.cmd, "rolled_back")
    end

    test "a box that comes back on its previous version after the restart failed it", ctx do
      ctx.box |> then(fn box -> ok(box, ctx.cmd, "0.2.0") end)
      ctx.cmd.op_id |> Operations.get!() |> age(:restart_reported_at, 60)

      rejoin(ctx.box, "0.1.0")

      assert %Operation{status: "failed", error: error} = Operations.get!(ctx.cmd.op_id)
      assert error =~ "came back on 0.1.0"
      # It's sent again: one failure might be bad luck.
      update_command()
    end

    test "the old release rejoining before it exits isn't a failure", ctx do
      ok(ctx.box, ctx.cmd, "0.2.0")
      rejoin(ctx.box, "0.1.0")
      assert %Operation{status: "running"} = Operations.get!(ctx.cmd.op_id)
    end

    test "an update that never finishes fails once it's overdue", ctx do
      ok(ctx.box, ctx.cmd, "0.2.0")
      ctx.cmd.op_id |> Operations.get!() |> age(:restart_reported_at, 11 * 60)
      Updates.sweep()

      assert %Operation{status: "failed", error: error} = Operations.get!(ctx.cmd.op_id)
      assert error =~ "didn't come back on 0.2.0"
      # The sweep sends it again to a box that's online.
      update_command()
    end

    test "one that's never answered fails after 20 minutes", ctx do
      ctx.cmd.op_id |> Operations.get!() |> age(:dispatched_at, 19 * 60)
      Updates.sweep()
      assert %Operation{status: "dispatched"} = Operations.get!(ctx.cmd.op_id)

      ctx.cmd.op_id |> Operations.get!() |> age(:dispatched_at, 21 * 60)
      Updates.sweep()
      assert %Operation{status: "failed"} = Operations.get!(ctx.cmd.op_id)
    end

    test "two failures with a success between them aren't in a row", ctx do
      register(ctx, "0.1.5", "linux-arm64")
      # 0.2.0 fails once (and is sent again at once)...
      failed(ctx.box, ctx.cmd)
      resent = update_command()
      assert resent.payload.version == "0.2.0"
      rejoin(ctx.box, "0.1.0")

      # ...an admin pins 0.1.5 meanwhile, which takes...
      {:ok, box} = Boxes.pin_agent_version(ctx.admin, ctx.box, "0.1.5")
      failed(box, resent)
      pinned = update_command()
      assert pinned.payload.version == "0.1.5"
      rejoin(box, "0.1.5")
      assert Operations.get!(pinned.op_id).status == "succeeded"

      # ...and back on the newest, 0.2.0 fails again: once in a row.
      {:ok, box} = Boxes.pin_agent_version(ctx.admin, box, nil)
      failed(box, update_command())
      assert Repo.reload!(box).failed_agent_version == nil
      assert update_command().payload.version == "0.2.0"
    end
  end

  describe "pinning" do
    setup ctx do
      register(ctx, "0.2.0", "linux-arm64")
      register(ctx, "0.3.0", "linux-arm64")
      %{box: linux_box(agent_version: "0.3.0") |> online()}
    end

    test "an admin pins a registered version, audited, and the box gets it", ctx do
      assert {:ok, box} = Boxes.pin_agent_version(ctx.admin, ctx.box, "0.2.0")
      assert box.desired_agent_version == "0.2.0"
      assert update_command().payload.version == "0.2.0"

      assert [%{action: "box.pin_agent_version", metadata: %{"version" => "0.2.0"}}] =
               Repo.all(Crew.Audit.Event)

      assert %{state: :updating, version: "0.2.0", pinned: true} = Updates.status(box)
    end

    test "unpinning follows the newest again", ctx do
      {:ok, box} = Boxes.pin_agent_version(ctx.admin, ctx.box, "0.2.0")
      cmd = update_command()
      rejoin(box, "0.2.0")
      assert Operations.get!(cmd.op_id).status == "succeeded"

      assert {:ok, box} = Boxes.pin_agent_version(ctx.admin, box, nil)
      assert box.desired_agent_version == nil
      assert update_command().payload.version == "0.3.0"
    end

    test "only to a version this box's target has", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Boxes.pin_agent_version(ctx.admin, ctx.box, "0.9.0")

      assert "there's no 0.9.0 release for linux-arm64" in errors_on(cs).desired_agent_version
      refute_receive {:dispatch, _}, 50
    end

    test "only by an admin", ctx do
      member = Scope.for_user(user_fixture())
      assert {:error, :unauthorized} = Boxes.pin_agent_version(member, ctx.box, "0.2.0")
    end

    test "a version that failed twice is sent again after Retry", ctx do
      box = ctx.box |> Ecto.Changeset.change(agent_version: "0.2.0") |> Repo.update!()
      rejoin(box, "0.2.0")
      failed(box, update_command())
      rejoin(box, "0.2.0")
      failed(box, update_command())
      box = Repo.reload!(box)
      assert box.failed_agent_version == "0.3.0"

      assert {:ok, box} = Boxes.retry_agent_update(ctx.admin, box)
      assert box.failed_agent_version == nil
      assert update_command().payload.version == "0.3.0"
      assert Enum.any?(Repo.all(Crew.Audit.Event), &(&1.action == "box.retry_agent_update"))
    end
  end

  test "a release registered later goes to the boxes online behind it", ctx do
    register(ctx, "0.1.0", "linux-arm64")
    box = linux_box() |> online()
    rejoin(box, "0.1.0")
    refute_receive {:dispatch, _}, 50

    write_release(ctx.dir, ctx.key, "0.2.0", "linux-arm64")
    assert %{registered: registered} = Releases.register_bundle(ctx.dir)
    assert registered >= 2
    assert update_command().payload.version == "0.2.0"
  end

  test "status says where a box is", ctx do
    register(ctx, "0.2.0", "linux-arm64")
    box = linux_box(agent_version: "0.2.0")
    assert %{state: :current, version: "0.2.0", pinned: false} = Updates.status(box)

    box = box |> Ecto.Changeset.change(agent_version: "0.1.0") |> Repo.update!()
    assert %{state: :pending, version: "0.2.0"} = Updates.status(box)
  end
end
