defmodule Crew.BoxesFlatcarTest do
  @moduledoc """
  A Flatcar box's Ignition from its join token (§12.2, §10.2): the
  token's box, its data disk and keys, the newest release, the release
  key and the box's Tailscale key; and the reprovision Ignition from the
  box page.
  """
  use Crew.DataCase

  import Crew.AgentReleaseFixtures

  alias Crew.Boxes
  alias Crew.Boxes.JoinToken
  alias Crew.ImageFixtures

  @key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyForCore crew-box@host"
  @break_glass "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBreakGlass admin@laptop"

  setup do
    key = ImageFixtures.keypair()
    ImageFixtures.trust(key)
    dir = tmp_dir("ignition-releases")
    write_release(dir, key, "0.3.0", "linux-arm64")
    write_release(dir, key, "0.3.0", "linux-amd64")
    Crew.Agents.Releases.register_bundle(dir)
    admin = Crew.Scope.for_user(user_fixture(role: "admin"))
    %{key: key, admin: admin}
  end

  defp token(admin, attrs) do
    {:ok, raw} =
      Boxes.create_join_token(
        admin,
        Map.merge(%{"box_name" => "m3max", "box_type" => "mac-vm"}, attrs)
      )

    raw
  end

  defp file(config, path) do
    f = Enum.find(config["storage"]["files"], &(&1["path"] == path)) || flunk("no #{path}")
    "data:;base64," <> b64 = f["contents"]["source"]
    Base.decode64!(b64)
  end

  test "renders the token's box with the newest release and the release key", %{
    admin: admin,
    key: key
  } do
    raw = token(admin, %{"ssh_keys" => @break_glass})

    assert {:ok, config, "m3max"} =
             Boxes.flatcar_ignition(raw, %{"arch" => "arm64", "ssh_keys" => [@key]})

    assert file(config, "/etc/hostname") == "m3max\n"
    env = file(config, "/etc/crew-box/provision.env")
    assert env =~ ~s(CREW_JOIN_TOKEN="#{raw}")
    assert env =~ ~s(CREW_URL="#{Crew.Config.base_url()}")

    release = file(config, "/etc/crew-box/release.env")
    assert release =~ ~s(CREW_VERSION="0.3.0")
    assert release =~ ~s(CREW_TARGET="linux-arm64")
    assert release =~ "/releases/download/v0.3.0/crew-agent-0.3.0-linux-arm64.tar.gz"
    assert release =~ ~s(CREW_RELEASE_PUBLIC_KEY="#{Base.encode64(key.public)}")

    core = Enum.find(config["passwd"]["users"], &(&1["name"] == "core"))
    assert core["sshAuthorizedKeys"] == [@break_glass, @key]
    assert file(config, "/etc/crew-box/format-data.sh") =~ "mkfs.xfs"
  end

  test "bare metal gets the data disk Add box was given", %{admin: admin} do
    raw = token(admin, %{"box_type" => "linux-metal", "data_disk" => "/dev/nvme1n1"})
    assert {:ok, config, _} = Boxes.flatcar_ignition(raw, %{"arch" => "amd64"})
    unit = Enum.find(config["systemd"]["units"], &(&1["name"] == "crew-format-data.service"))
    assert unit["contents"] =~ "format-data.sh /dev/nvme1n1"
  end

  test "the token stays good for the agent's own enrollment, once", %{admin: admin} do
    raw = token(admin, %{})
    assert {:ok, _, _} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
    assert {:ok, _, _} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})

    {public, _} = CrewProtocol.Auth.generate_keypair()
    assert {:ok, _box} = Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})
    assert {:error, :invalid_token} = Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})
    assert {:error, :invalid_token} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
  end

  test "refuses an expired token, a bad one and a mac-vz box's", %{admin: admin} do
    assert {:error, :invalid_token} = Boxes.flatcar_ignition("cj_nope", %{"arch" => "arm64"})
    assert {:error, :invalid_token} = Boxes.flatcar_ignition(nil, %{"arch" => "arm64"})

    vz = token(admin, %{"box_name" => "m1ultra", "box_type" => "mac-vz"})
    assert {:error, :not_flatcar} = Boxes.flatcar_ignition(vz, %{"arch" => "arm64"})

    late = token(admin, %{"box_name" => "late"})
    Repo.update_all(JoinToken, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])
    assert {:error, :invalid_token} = Boxes.flatcar_ignition(late, %{"arch" => "arm64"})
  end

  test "refuses an arch Flatcar doesn't ship and a key that isn't one", %{admin: admin} do
    raw = token(admin, %{})
    assert {:error, :bad_arch} = Boxes.flatcar_ignition(raw, %{"arch" => "x86_64"})

    assert {:error, :bad_ssh_key} =
             Boxes.flatcar_ignition(raw, %{"arch" => "arm64", "ssh_keys" => ["nope"]})
  end

  test "without a release for the arch, says so", %{admin: admin} do
    Repo.delete_all(Crew.Agents.Release)
    raw = token(admin, %{})
    assert {:error, :no_release} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
  end

  describe "the Tailscale key" do
    test "is the one pasted on Add box", %{admin: admin} do
      raw = token(admin, %{"tailscale_auth_key" => "tskey-auth-pasted-1234"})
      {:ok, config, _} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
      assert file(config, "/etc/crew-box/tailscale-authkey") == "tskey-auth-pasted-1234"
    end

    test "is minted once with the OAuth client, and forgotten at enrollment", %{admin: admin} do
      Application.put_env(:crew, :tailscale, %{
        client_id: "kXYZ",
        client_secret: "tskey-client-s",
        tailnet: "-"
      })

      on_exit(fn -> Application.delete_env(:crew, :tailscale) end)
      test = self()

      Req.Test.stub(Crew.Tailscale, fn conn ->
        case conn.request_path do
          "/api/v2/oauth/token" ->
            Req.Test.json(conn, %{"access_token" => "tok", "expires_in" => 3600})

          "/api/v2/tailnet/-/keys" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test, {:key_request, Jason.decode!(body)})

            Req.Test.json(conn, %{
              "key" => "tskey-auth-minted-#{System.unique_integer([:positive])}",
              "id" => "k1"
            })
        end
      end)

      raw = token(admin, %{})
      {:ok, config, _} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
      key = file(config, "/etc/crew-box/tailscale-authkey")
      assert key =~ "tskey-auth-minted-"

      assert_received {:key_request,
                       %{"capabilities" => %{"devices" => %{"create" => create}}} = req}

      assert create["tags"] == ["tag:crew-box"]
      assert create["preauthorized"] == true
      assert create["reusable"] == false
      assert req["expirySeconds"] > 0 and req["expirySeconds"] <= 3600

      # Asked again: the same key, not another.
      {:ok, again, _} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
      assert file(again, "/etc/crew-box/tailscale-authkey") == key
      refute_received {:key_request, _}

      {public, _} = CrewProtocol.Auth.generate_keypair()
      {:ok, _} = Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})
      assert Repo.one(from t in JoinToken, select: t.tailscale_auth_key) == nil
    end

    test "a failed mint is an error, not a box without the tailnet", %{admin: admin} do
      Application.put_env(:crew, :tailscale, %{
        client_id: "kXYZ",
        client_secret: "s",
        tailnet: "-"
      })

      on_exit(fn -> Application.delete_env(:crew, :tailscale) end)

      Req.Test.stub(Crew.Tailscale, fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "no"})
      end)

      raw = token(admin, %{})
      assert {:error, {:tailscale, _}} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
    end

    test "is none without either, and the box reaches the control plane as it is", %{admin: admin} do
      {:ok, config, _} = Boxes.flatcar_ignition(token(admin, %{}), %{"arch" => "arm64"})

      refute Enum.any?(
               config["storage"]["files"],
               &(&1["path"] == "/etc/crew-box/tailscale-authkey")
             )
    end
  end

  describe "Add box" do
    test "keeps the break-glass key and checks it", %{admin: admin} do
      token(admin, %{"ssh_keys" => @break_glass})
      assert Repo.one(from t in JoinToken, select: t.ssh_keys) == [@break_glass]

      assert {:error, cs} =
               Boxes.create_join_token(admin, %{
                 "box_name" => "x",
                 "box_type" => "mac-vm",
                 "ssh_keys" => "not a key"
               })

      assert errors_on(cs)[:ssh_keys]
    end

    test "needs the data disk for bare metal, and a device path", %{admin: admin} do
      assert {:error, cs} =
               Boxes.create_join_token(admin, %{
                 "box_name" => "metal",
                 "box_type" => "linux-metal"
               })

      assert errors_on(cs)[:data_disk]

      assert {:error, cs} =
               Boxes.create_join_token(admin, %{
                 "box_name" => "metal",
                 "box_type" => "linux-metal",
                 "data_disk" => "/dev/sdb; reboot"
               })

      assert errors_on(cs)[:data_disk]

      assert {:ok, _} =
               Boxes.create_join_token(admin, %{
                 "box_name" => "metal",
                 "box_type" => "linux-metal",
                 "data_disk" => "/dev/disk/by-id/nvme-Samsung_SSD_990"
               })
    end

    test "checks a pasted Tailscale key looks like one", %{admin: admin} do
      assert {:error, cs} =
               Boxes.create_join_token(admin, %{
                 "box_name" => "x",
                 "box_type" => "linux-vm",
                 "tailscale_auth_key" => "hello"
               })

      assert errors_on(cs)[:tailscale_auth_key]
    end
  end

  describe "the reprovision Ignition" do
    setup %{admin: admin} do
      raw =
        token(admin, %{
          "box_name" => "metal",
          "box_type" => "linux-metal",
          "data_disk" => "/dev/sdb"
        })

      {public, _} = CrewProtocol.Auth.generate_keypair()
      {:ok, box} = Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})
      %{box: box}
    end

    test "has no token or Tailscale key, and keeps the data disk the box was added with", %{
      admin: admin,
      box: box
    } do
      assert {:ok, config} = Boxes.reprovision_ignition(admin, box, %{"arch" => "amd64"})
      text = Jason.encode!(config)
      refute text =~ "cj_"
      refute text =~ "tskey"
      unit = Enum.find(config["systemd"]["units"], &(&1["name"] == "crew-format-data.service"))
      assert unit["contents"] =~ "format-data.sh /dev/sdb"
      assert Boxes.data_disk(box) == "/dev/sdb"
    end

    test "takes another data disk and a break-glass key", %{admin: admin, box: box} do
      assert {:ok, config} =
               Boxes.reprovision_ignition(admin, box, %{
                 "arch" => "amd64",
                 "data_disk" => "/dev/sdc",
                 "ssh_keys" => @break_glass
               })

      unit = Enum.find(config["systemd"]["units"], &(&1["name"] == "crew-format-data.service"))
      assert unit["contents"] =~ "format-data.sh /dev/sdc"

      assert Enum.find(config["passwd"]["users"], &(&1["name"] == "core"))["sshAuthorizedKeys"] ==
               [@break_glass]
    end

    test "is for admins and Flatcar boxes only", %{box: box} do
      member = Crew.Scope.for_user(user_fixture())

      assert {:error, :unauthorized} =
               Boxes.reprovision_ignition(member, box, %{"arch" => "amd64"})

      admin = Crew.Scope.for_user(user_fixture(role: "admin"))
      vz = Repo.update!(Ecto.Changeset.change(box, type: "mac-vz"))
      assert {:error, :not_flatcar} = Boxes.reprovision_ignition(admin, vz, %{"arch" => "arm64"})
    end
  end
end
