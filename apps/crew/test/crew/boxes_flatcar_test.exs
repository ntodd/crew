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
  @os_disk "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0W"
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
        Map.merge(%{"box_name" => "m3max", "box_type" => "linux-vm"}, attrs)
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

  defp format_unit(config),
    do: Enum.find(config["systemd"]["units"], &(&1["name"] == "crew-format-data.service"))

  test "bare metal with one disk gets partition 10 of the OS disk Add box was given", %{
    admin: admin
  } do
    raw = token(admin, %{"box_type" => "linux-metal", "os_disk" => @os_disk})
    assert {:ok, config, _} = Boxes.flatcar_ignition(raw, %{"arch" => "amd64"})
    assert [%{"device" => @os_disk}] = config["storage"]["disks"]
    assert format_unit(config)["contents"] =~ "format-data.sh --partition #{@os_disk}-part10"
  end

  test "bare metal with a separate data disk gets the one Add box was given", %{admin: admin} do
    raw =
      token(admin, %{
        "box_type" => "linux-metal",
        "disk_layout" => "separate",
        "os_disk" => @os_disk,
        "data_disk" => "/dev/nvme1n1"
      })

    assert {:ok, config, _} = Boxes.flatcar_ignition(raw, %{"arch" => "amd64"})
    refute config["storage"]["disks"]
    assert format_unit(config)["contents"] =~ "format-data.sh /dev/nvme1n1"
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

    test "a key minted while the box enrolled isn't kept or handed out", %{admin: admin} do
      Application.put_env(:crew, :tailscale, %{
        client_id: "kXYZ",
        client_secret: "tskey-client-s",
        tailnet: "-"
      })

      on_exit(fn -> Application.delete_env(:crew, :tailscale) end)
      raw = token(admin, %{})

      Req.Test.stub(Crew.Tailscale, fn conn ->
        case conn.request_path do
          "/api/v2/oauth/token" ->
            Req.Test.json(conn, %{"access_token" => "tok", "expires_in" => 3600})

          "/api/v2/tailnet/-/keys" ->
            # The box enrolls while Tailscale makes the key.
            {public, _} = CrewProtocol.Auth.generate_keypair()
            {:ok, _} = Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})
            Req.Test.json(conn, %{"key" => "tskey-auth-late", "id" => "k1"})
        end
      end)

      assert {:error, :invalid_token} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
      assert Repo.one(from t in JoinToken, select: t.tailscale_auth_key) == nil
    end

    test "a token cancelled while its key is minted is refused, not a crash", %{admin: admin} do
      Application.put_env(:crew, :tailscale, %{
        client_id: "kXYZ",
        client_secret: "tskey-client-s",
        tailnet: "-"
      })

      on_exit(fn -> Application.delete_env(:crew, :tailscale) end)
      raw = token(admin, %{})

      Req.Test.stub(Crew.Tailscale, fn conn ->
        case conn.request_path do
          "/api/v2/oauth/token" ->
            Req.Test.json(conn, %{"access_token" => "tok", "expires_in" => 3600})

          "/api/v2/tailnet/-/keys" ->
            :ok = Boxes.cancel_join_token(admin, raw)
            Req.Test.json(conn, %{"key" => "tskey-auth-late", "id" => "k1"})
        end
      end)

      assert {:error, :invalid_token} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})
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
                 "box_type" => "linux-vm",
                 "ssh_keys" => "not a key"
               })

      assert errors_on(cs)[:ssh_keys]
    end

    defp metal(admin, attrs) do
      Boxes.create_join_token(
        admin,
        Map.merge(%{"box_name" => "metal", "box_type" => "linux-metal"}, attrs)
      )
    end

    test "bare metal is one disk unless it's told otherwise, and needs it by id", %{
      admin: admin
    } do
      assert {:error, cs} = metal(admin, %{})
      assert errors_on(cs)[:os_disk]
      refute errors_on(cs)[:data_disk]

      for bad <- ["/dev/nvme0n1", "/dev/disk/by-id/x; reboot", "/dev/disk/by-id/../sda"] do
        assert {:error, cs} = metal(admin, %{"os_disk" => bad})
        assert errors_on(cs)[:os_disk] == ["must be a /dev/disk/by-id/... link"], bad
      end

      # A data disk means nothing with one disk.
      assert {:ok, _} = metal(admin, %{"os_disk" => @os_disk, "data_disk" => "/dev/sdb"})

      assert %JoinToken{disk_layout: "one", os_disk: @os_disk, data_disk: nil} =
               Repo.one!(JoinToken)
    end

    # The OS disk is by id with a data disk too: the live image a
    # reprovision boots can number the disks the other way round, and
    # flatcar-install writes over whichever its command names.
    test "a separate data disk needs both disks, the OS disk by id, and two of them", %{
      admin: admin
    } do
      separate = &metal(admin, Map.put(&1, "disk_layout", "separate"))

      assert {:error, cs} = separate.(%{})
      assert errors_on(cs)[:os_disk]
      assert errors_on(cs)[:data_disk]

      assert {:error, cs} = separate.(%{"os_disk" => @os_disk, "data_disk" => "/dev/sdb; reboot"})
      assert errors_on(cs)[:data_disk]

      assert {:error, cs} = separate.(%{"os_disk" => "/dev/sda", "data_disk" => "/dev/sdb"})
      assert errors_on(cs)[:os_disk] == ["must be a /dev/disk/by-id/... link"]

      assert {:error, cs} = separate.(%{"os_disk" => @os_disk, "data_disk" => @os_disk})
      assert errors_on(cs)[:data_disk] == ["must be another disk than the OS disk"]

      assert {:ok, _} = separate.(%{"os_disk" => @os_disk, "data_disk" => "/dev/sdb"})

      assert %JoinToken{disk_layout: "separate", os_disk: @os_disk, data_disk: "/dev/sdb"} =
               Repo.one!(JoinToken)
    end

    test "knows the two layouts", %{admin: admin} do
      assert {:error, cs} = metal(admin, %{"disk_layout" => "raid", "os_disk" => @os_disk})
      assert errors_on(cs)[:disk_layout]
    end

    test "keeps no disks for the VMs, whose disks are the launchers'", %{admin: admin} do
      token(admin, %{"os_disk" => @os_disk, "disk_layout" => "one", "data_disk" => "/dev/sdb"})

      assert %JoinToken{disk_layout: nil, os_disk: nil, data_disk: nil} = Repo.one!(JoinToken)
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

  defp enroll(raw) do
    {public, _} = CrewProtocol.Auth.generate_keypair()
    {:ok, box} = Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})
    box
  end

  describe "the reprovision Ignition" do
    setup %{admin: admin} do
      raw =
        token(admin, %{
          "box_name" => "metal",
          "box_type" => "linux-metal",
          "disk_layout" => "separate",
          "os_disk" => @os_disk,
          "data_disk" => "/dev/sdb"
        })

      %{box: enroll(raw)}
    end

    test "has no token or Tailscale key, and keeps the data disk the box was added with", %{
      admin: admin,
      box: box
    } do
      assert {:ok, config} = Boxes.reprovision_ignition(admin, box, %{"arch" => "amd64"})
      text = Jason.encode!(config)
      refute text =~ "cj_"
      refute text =~ "tskey"
      assert format_unit(config)["contents"] =~ "format-data.sh /dev/sdb"
      refute config["storage"]["disks"]

      assert Boxes.disks(box) == %{
               disk_layout: "separate",
               os_disk: @os_disk,
               data_disk: "/dev/sdb"
             }
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

  describe "a one-disk box's reprovision Ignition" do
    setup %{admin: admin} do
      raw =
        token(admin, %{"box_name" => "metal", "box_type" => "linux-metal", "os_disk" => @os_disk})

      %{box: enroll(raw)}
    end

    test "finds partition 10 of the OS disk again, and never wipes it", %{admin: admin, box: box} do
      assert Boxes.disks(box) == %{disk_layout: "one", os_disk: @os_disk, data_disk: nil}

      assert {:ok, config} = Boxes.reprovision_ignition(admin, box, %{"arch" => "amd64"})
      assert [%{"device" => @os_disk, "wipeTable" => false}] = config["storage"]["disks"]
      assert format_unit(config)["contents"] =~ "--partition #{@os_disk}-part10"
      refute Enum.any?(config["storage"]["files"], &(&1["path"] == "/etc/crew-box/fresh-data"))
    end

    test "takes the OS disk under another id, but stays one disk", %{admin: admin, box: box} do
      other = "/dev/disk/by-id/nvme-eui.0025385b71b0e2c1"

      assert {:ok, config} =
               Boxes.reprovision_ignition(admin, box, %{
                 "arch" => "amd64",
                 "os_disk" => other,
                 "data_disk" => "/dev/sdb",
                 "disk_layout" => "separate"
               })

      assert [%{"device" => ^other}] = config["storage"]["disks"]
      refute Jason.encode!(config) =~ "/dev/sdb"

      assert {:error, :bad_os_disk} =
               Boxes.reprovision_ignition(admin, box, %{
                 "arch" => "amd64",
                 "os_disk" => "/dev/sda"
               })

      # Blank is the box's own.
      assert {:ok, config} =
               Boxes.reprovision_ignition(admin, box, %{"arch" => "amd64", "os_disk" => "   "})

      assert [%{"device" => @os_disk}] = config["storage"]["disks"]
    end
  end

  # The token that enrolled the box says how it's laid out. Another made
  # for the same name meanwhile can't enroll it again with its own layout.
  test "a box's disks are the token's that enrolled it", %{admin: admin} do
    first =
      token(admin, %{"box_name" => "metal", "box_type" => "linux-metal", "os_disk" => @os_disk})

    second =
      token(admin, %{
        "box_name" => "metal",
        "box_type" => "linux-metal",
        "disk_layout" => "separate",
        "os_disk" => @os_disk,
        "data_disk" => "/dev/sdb"
      })

    box = enroll(first)
    {public, _} = CrewProtocol.Auth.generate_keypair()

    assert {:error, :invalid_token} =
             Boxes.enroll(second, %{"public_key" => Base.encode64(public)})

    assert Boxes.disks(box).disk_layout == "one"
  end

  # Boxes added before one disk was the default (#140) have a data disk
  # and no layout, and keep the reprovision Ignition they had.
  test "a box added before layouts has a separate data disk", %{admin: admin} do
    raw = token(admin, %{"box_name" => "old", "box_type" => "linux-vm"})
    box = enroll(raw)

    Repo.update_all(JoinToken, set: [box_type: "linux-metal", data_disk: "/dev/sdb"])
    box = Repo.update!(Ecto.Changeset.change(box, type: "linux-metal"))

    assert Boxes.disks(box) == %{disk_layout: "separate", os_disk: nil, data_disk: "/dev/sdb"}
    assert {:ok, config} = Boxes.reprovision_ignition(admin, box, %{"arch" => "amd64"})
    assert format_unit(config)["contents"] =~ "format-data.sh /dev/sdb"
  end
end
