defmodule Crew.BoxesTest do
  use Crew.DataCase

  alias Crew.{Boxes, Scope}

  setup do
    %{admin: Scope.for_user(user_fixture(role: "admin"))}
  end

  defp enroll_attrs(public) do
    %{
      "public_key" => Base.encode64(public),
      "agent_version" => "0.1.0",
      "os" => "darwin",
      "arch" => "arm64"
    }
  end

  describe "join tokens and enrollment (§10.2)" do
    test "retired Mac workers cannot be added or enroll with a previously issued token", %{
      admin: admin
    } do
      attrs = %{"box_name" => "old-mac", "box_type" => "mac-vm"}
      assert {:error, cs} = Boxes.create_join_token(admin, attrs)
      assert errors_on(cs)[:box_type]

      {:ok, raw} = Boxes.create_join_token(admin, %{attrs | "box_type" => "linux-vm"})
      Repo.update_all(Crew.Boxes.JoinToken, set: [box_type: "mac-vm"])
      {public, _} = CrewProtocol.Auth.generate_keypair()
      assert {:error, :invalid_token} = Boxes.enroll(raw, enroll_attrs(public))
      assert {:error, _} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
      refute Boxes.get_by_name("old-mac")
    end

    test "a retired worker drains and keeps its original identity during migration", %{
      admin: admin
    } do
      attrs = %{"box_name" => "old-mac", "box_type" => "mac-vz"}
      {:ok, stale_token} = Boxes.create_join_token(admin, attrs)
      box = box_fixture(name: "old-mac", type: "mac-vm", draining: false)
      assert :draining in Boxes.issues(box, true)
      assert Enum.find(Crew.Scheduler.snapshot().boxes, &(&1.id == box.id)).draining

      assert {:error, cs} =
               Boxes.create_join_token(admin, %{"box_name" => box.name, "box_type" => "mac-vz"})

      assert errors_on(cs)[:box_name]
      {replacement_key, _} = CrewProtocol.Auth.generate_keypair()
      assert {:error, :invalid_token} = Boxes.enroll(stale_token, enroll_attrs(replacement_key))
      assert Boxes.public_key(box.id) == {:ok, box.public_key}
    end

    test "a join token can't name a box that's already enrolled", %{admin: admin} do
      box = box_fixture(name: "m1ultra")

      assert {:error, cs} =
               Boxes.create_join_token(admin, %{"box_name" => box.name, "box_type" => "mac-vz"})

      assert errors_on(cs)[:box_name] |> Enum.any?(&(&1 =~ "already enrolled"))
    end

    test "a second token for one name can't take over the box the first enrolled", %{
      admin: admin
    } do
      attrs = %{"box_name" => "m1ultra", "box_type" => "mac-vz"}
      {:ok, first} = Boxes.create_join_token(admin, attrs)
      {:ok, second} = Boxes.create_join_token(admin, attrs)
      {key, _} = CrewProtocol.Auth.generate_keypair()
      {:ok, box} = Boxes.enroll(first, enroll_attrs(key))

      {other, _} = CrewProtocol.Auth.generate_keypair()
      assert {:error, :invalid_token} = Boxes.enroll(second, enroll_attrs(other))
      assert Boxes.public_key(box.id) == {:ok, key}
    end

    test "enrolling spends the other tokens made for its name", %{admin: admin} do
      attrs = %{"box_name" => "fc1", "box_type" => "linux-vm"}
      {:ok, first} = Boxes.create_join_token(admin, attrs)
      {:ok, second} = Boxes.create_join_token(admin, attrs)
      {key, _} = CrewProtocol.Auth.generate_keypair()
      {:ok, _} = Boxes.enroll(first, enroll_attrs(key))

      assert {:error, :invalid_token} = Boxes.flatcar_ignition(second, %{"arch" => "amd64"})

      refute Repo.exists?(
               from t in Crew.Boxes.JoinToken, where: t.box_name == "fc1" and is_nil(t.used_at)
             )
    end

    test "a token enrolls a box once, and only its hash is stored", %{admin: admin} do
      {:ok, raw} =
        Boxes.create_join_token(admin, %{"box_name" => "m1ultra", "box_type" => "mac-vz"})

      assert String.starts_with?(raw, "cj_")
      refute Repo.exists?(from t in Crew.Boxes.JoinToken, where: t.token_hash == ^raw)

      {public, _} = CrewProtocol.Auth.generate_keypair()
      Phoenix.PubSub.subscribe(Crew.PubSub, "boxes")
      assert {:ok, box} = Boxes.enroll(raw, enroll_attrs(public))
      assert_received {:box_changed, _}
      assert box.name == "m1ultra"
      assert box.type == "mac-vz"
      assert box.public_key == public
      assert box.key_fingerprint == CrewProtocol.Auth.fingerprint(public)

      assert {:error, :invalid_token} = Boxes.enroll(raw, enroll_attrs(public))
    end

    test "network settings survive enrollment and reprovision", %{admin: admin} do
      attrs = %{
        "box_name" => "nettest",
        "box_type" => "linux-vm",
        "uplink" => "eno2",
        "extra_blocked" => "198.51.100.9"
      }

      assert {:error, _} =
               Boxes.create_join_token(admin, Map.put(attrs, "extra_blocked", "invalid"))

      assert {:ok, raw} = Boxes.create_join_token(admin, attrs)
      {key, _} = CrewProtocol.Auth.generate_keypair()
      {:ok, box} = Boxes.enroll(raw, enroll_attrs(key))
      assert {:ok, config} = Boxes.reprovision_ignition(admin, box, %{"arch" => "amd64"})

      for {path, content} <- [{"uplink", "eno2"}, {"extra-blocked", "198.51.100.9"}] do
        file = Enum.find(config["storage"]["files"], &(&1["path"] == "/etc/crew-box/" <> path))
        assert file["contents"]["source"] == "data:;base64," <> Base.encode64(content <> "\n")
      end
    end

    test "tokens expire after an hour", %{admin: admin} do
      {:ok, raw} =
        Boxes.create_join_token(admin, %{
          "box_name" => "late",
          "box_type" => "linux-metal",
          "os_disk" => "/dev/disk/by-id/nvme-Samsung_SSD_990"
        })

      Repo.update_all(Crew.Boxes.JoinToken,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      {public, _} = CrewProtocol.Auth.generate_keypair()
      assert {:error, :invalid_token} = Boxes.enroll(raw, enroll_attrs(public))
    end

    test "names are DNS labels of at most 40, and types are restricted", %{admin: admin} do
      assert {:error, cs} =
               Boxes.create_join_token(admin, %{"box_name" => "Not OK", "box_type" => "mac-vz"})

      assert errors_on(cs)[:box_name]

      assert {:error, cs} =
               Boxes.create_join_token(admin, %{
                 "box_name" => String.duplicate("a", 41),
                 "box_type" => "mac-vz"
               })

      assert errors_on(cs)[:box_name]

      assert {:error, cs} =
               Boxes.create_join_token(admin, %{"box_name" => "ok", "box_type" => "windows"})

      assert errors_on(cs)[:box_type]
    end

    test "only admins create tokens" do
      member = Scope.for_user(user_fixture())

      assert {:error, :unauthorized} =
               Boxes.create_join_token(member, %{"box_name" => "x", "box_type" => "mac-vz"})
    end

    test "a bad public key is refused", %{admin: admin} do
      {:ok, raw} = Boxes.create_join_token(admin, %{"box_name" => "k", "box_type" => "mac-vz"})
      assert {:error, :bad_key} = Boxes.enroll(raw, %{"public_key" => "short"})
      # And doesn't spend the token.
      {public, _} = CrewProtocol.Auth.generate_keypair()
      assert {:ok, _} = Boxes.enroll(raw, enroll_attrs(public))
    end

    test "a revoked box's name can't be enrolled again", %{admin: admin} do
      attrs = %{"box_name" => "gone", "box_type" => "mac-vz"}
      {:ok, early} = Boxes.create_join_token(admin, attrs)
      box = box_fixture(name: "gone")
      {:ok, _} = Boxes.revoke(admin, box)

      assert {:error, cs} = Boxes.create_join_token(admin, attrs)
      assert errors_on(cs)[:box_name] |> Enum.any?(&(&1 =~ "revoked"))
      {public, _} = CrewProtocol.Auth.generate_keypair()
      assert {:error, :invalid_token} = Boxes.enroll(early, enroll_attrs(public))
    end
  end

  describe "public keys" do
    test "a live box's key, nothing for revoked or unknown ones", %{admin: admin} do
      box = box_fixture()
      assert {:ok, key} = Boxes.public_key(box.id)
      assert key == box.public_key

      {:ok, _} = Boxes.revoke(admin, box)
      assert :error = Boxes.public_key(box.id)
      assert :error = Boxes.public_key("not-a-uuid")
      assert :error = Boxes.public_key(CrewProtocol.uuid7())
    end
  end

  describe "capabilities are pinned at enrollment (§8.3)" do
    test "the first report is pinned, and waits for an admin", %{admin: admin} do
      box = box_fixture(capabilities: nil, pinned_capabilities: nil)
      {:ok, box} = Boxes.report_capabilities(box, capabilities())
      assert box.pinned_capabilities["vcpus"] == 18
      assert box.needs_approval
      assert box.driver == "vz"
      assert box.guest_arch == "arm64"
      assert :needs_approval in Boxes.issues(box, true)

      # It waits however often it reports.
      {:ok, box} = Boxes.report_capabilities(box, capabilities())
      assert box.needs_approval

      {:ok, box} = Boxes.approve_capabilities(admin, box, Boxes.report_digest(box))
      refute box.needs_approval
      {:ok, box} = Boxes.report_capabilities(box, capabilities())
      refute box.needs_approval
    end

    test "a report read before an approval still needs its own", %{admin: admin} do
      box = box_fixture(capabilities: nil, pinned_capabilities: nil)
      {:ok, box} = Boxes.report_capabilities(box, capabilities())
      # What the agent's handler read, before the admin accepted.
      stale = Boxes.get!(box.id)
      {:ok, _} = Boxes.approve_capabilities(admin, box, Boxes.report_digest(box))

      {:ok, _} = Boxes.report_capabilities(stale, capabilities(guest_arch: "x64"))
      assert Boxes.get!(box.id).needs_approval
    end

    test "an admin accepts the report they saw, not a newer one", %{admin: admin} do
      box = box_fixture(capabilities: nil, pinned_capabilities: nil)
      {:ok, seen} = Boxes.report_capabilities(box, capabilities())
      {:ok, newer} = Boxes.report_capabilities(seen, capabilities(vcpus: 4096))

      assert {:error, :stale} =
               Boxes.approve_capabilities(admin, newer, Boxes.report_digest(seen))

      assert Boxes.get!(box.id).needs_approval

      assert {:ok, box} = Boxes.approve_capabilities(admin, newer, Boxes.report_digest(newer))
      assert box.pinned_capabilities["vcpus"] == 4096
    end

    test "small changes are reported but don't move the pinned baseline" do
      box = box_fixture()
      {:ok, box} = Boxes.report_capabilities(box, capabilities(vcpus: 17))
      refute box.needs_approval
      assert box.capabilities["vcpus"] == 17
      assert box.pinned_capabilities["vcpus"] == 18
    end

    test "creeping up 9% at a time still needs approval" do
      box = box_fixture()

      box =
        Enum.reduce(1..5, box, fn i, box ->
          {:ok, box} =
            Boxes.report_capabilities(
              box,
              capabilities(memory_mib: round(110_592 * :math.pow(1.09, i)))
            )

          box
        end)

      assert box.needs_approval
      assert box.pinned_capabilities["memory_mib"] == 110_592
    end

    test "a change of arch or driver, or over 10%, needs approval" do
      box = box_fixture()

      {:ok, box} = Boxes.report_capabilities(box, capabilities(memory_mib: 200_000))
      assert box.needs_approval
      assert box.capabilities["memory_mib"] == 200_000
      # Placement keeps using the pinned values until an admin accepts.
      assert box.pinned_capabilities["memory_mib"] == 110_592

      box2 = box_fixture()
      {:ok, box2} = Boxes.report_capabilities(box2, capabilities(guest_arch: "x64"))
      assert box2.needs_approval
    end

    test "an admin accepts the change, and it's audited", %{admin: admin} do
      box = box_fixture()
      {:ok, box} = Boxes.report_capabilities(box, capabilities(vcpus: 64, max_vcpus_per_vm: 64))
      {:ok, box} = Boxes.approve_capabilities(admin, box, Boxes.report_digest(box))
      refute box.needs_approval
      assert box.pinned_capabilities["vcpus"] == 64
      assert Enum.any?(Crew.Audit.recent(), &(&1.action == "box.capabilities_approved"))
    end

    test "firewall and virtualisation come from the report" do
      box = box_fixture()

      {:ok, box} =
        Boxes.report_capabilities(
          box,
          capabilities(firewall_ok: false, virtualized: true, hypervisor_vendor: "Apple")
        )

      refute box.firewall_ok
      assert box.virtualized
      assert box.hypervisor_vendor == "Apple"
    end
  end

  describe "capacity overrides (§8.3)" do
    test "spare_pct is 0 to 100, or unset for the default" do
      box = box_fixture()

      for pct <- [0, 50, 100, nil] do
        assert Boxes.change_overrides(box, %{spare_pct: pct}).valid?, inspect(pct)
      end

      assert Boxes.change_overrides(box, %{spare_pct: ""}).valid?

      for pct <- [-1, 101] do
        refute Boxes.change_overrides(box, %{spare_pct: pct}).valid?, inspect(pct)
      end
    end

    test "a spare_pct change is audited with the other overrides", %{admin: admin} do
      box = box_fixture()
      {:ok, box} = Boxes.update_overrides(admin, box, %{"spare_pct" => "30", "max_vms" => "6"})
      assert box.spare_pct == 30

      assert [%{action: "box.overrides", metadata: %{"spare_pct" => 30, "max_vms" => 6}} | _] =
               Crew.Audit.recent()

      {:ok, box} = Boxes.update_overrides(admin, box, %{"spare_pct" => ""})
      assert box.spare_pct == nil
    end
  end

  describe "joins and leaves" do
    test "a join records the agent and marks the box online; a leave marks it offline" do
      box = box_fixture()
      Phoenix.PubSub.subscribe(Crew.PubSub, "boxes")

      join = %{
        agent_version: "0.2.0",
        protocol_version: 1,
        box_name: box.name,
        os: "darwin",
        arch: "arm64",
        boot_id: Ecto.UUID.generate(),
        in_flight: []
      }

      box = Boxes.agent_joined(box, join)
      assert box.agent_version == "0.2.0"
      assert box.online_at
      assert_received {:box_changed, id} when id == box.id

      Boxes.agent_left(box.id)
      assert Boxes.get!(box.id).offline_at
    end
  end

  test "revoking deletes the key, drops the socket and is audited", %{admin: admin} do
    box = box_fixture()
    CrewWeb.Endpoint.subscribe("agent_socket:#{box.id}")
    {:ok, box} = Boxes.revoke(admin, box)
    assert box.revoked_at
    assert is_nil(box.public_key)
    assert_received %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert Enum.any?(Crew.Audit.recent(), &(&1.action == "box.revoke"))
  end

  describe "issues/3" do
    @now ~U[2026-11-06 12:00:00.000000Z]

    test "a healthy online box has none" do
      assert Boxes.issues(box_fixture(), true, @now) == []
    end

    test "what keeps a box from taking jobs comes first, the rest after" do
      box =
        box_fixture(
          firewall_ok: false,
          needs_approval: true,
          draining: true,
          quarantined_until: DateTime.add(@now, 600)
        )
        |> Ecto.Changeset.change(reboot_required: true, sleep_disabled: false)
        |> Repo.update!()

      assert Boxes.issues(box, false, @now) ==
               [
                 :offline,
                 :firewall,
                 :needs_approval,
                 :quarantined,
                 :draining,
                 :sleep_on,
                 :reboot_required
               ]
    end

    test "a quarantine that's over isn't one" do
      box = box_fixture(quarantined_until: DateTime.add(@now, -1))
      assert Boxes.issues(box, true, @now) == []
    end

    test "a box whose agent hasn't reported yet says so, not that its firewall is off" do
      box = box_fixture(firewall_ok: false, pinned_capabilities: nil)
      assert Boxes.issues(box, true, @now) == [:not_reported]
    end

    test "blocking?/1 is whether placement skips the box for it (§8.3)" do
      assert Enum.filter(
               [
                 :offline,
                 :not_reported,
                 :firewall,
                 :needs_approval,
                 :quarantined,
                 :draining,
                 :sleep_on,
                 :reboot_required
               ],
               &Boxes.blocking?/1
             ) == [:offline, :not_reported, :firewall, :needs_approval, :quarantined, :draining]
    end
  end
end
