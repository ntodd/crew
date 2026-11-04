defmodule CrewWeb.AgentControllerTest do
  use CrewWeb.ConnCase

  setup do
    admin = Crew.Scope.for_user(user_fixture(role: "admin"))

    {:ok, token} =
      Crew.Boxes.create_join_token(admin, %{"box_name" => "m1ultra", "box_type" => "mac-vz"})

    {public, _} = CrewProtocol.Auth.generate_keypair()
    %{token: token, key: Base.encode64(public)}
  end

  test "enrolls with a join token", %{conn: conn, token: token, key: key} do
    conn =
      post(conn, ~p"/api/agents/enroll", %{
        "join_token" => token,
        "public_key" => key,
        "agent_version" => "0.1.0"
      })

    assert %{"agent_id" => id, "box" => "m1ultra", "type" => "mac-vz"} = json_response(conn, 201)
    assert Crew.Boxes.get!(id).agent_version == "0.1.0"
  end

  test "a spent token is refused", %{conn: conn, token: token, key: key} do
    post(conn, ~p"/api/agents/enroll", %{"join_token" => token, "public_key" => key})

    conn =
      post(build_conn(), ~p"/api/agents/enroll", %{"join_token" => token, "public_key" => key})

    assert json_response(conn, 401)["error"] =~ "invalid"
  end

  test "bad tokens from one client are limited, without blocking another", %{key: key} do
    ip = "100.64.#{:rand.uniform(250)}.#{:rand.uniform(250)}"

    req = fn ip ->
      build_conn()
      |> put_req_header("x-forwarded-for", ip)
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post(~p"/api/agents/enroll", %{"join_token" => "cj_nope", "public_key" => key})
    end

    for _ <- 1..10, do: assert(req.(ip).status == 401)
    assert req.(ip).status == 429
    assert req.("100.64.0.9").status == 401
  end

  describe "POST /agent/flatcar/ignition" do
    setup do
      key = Crew.ImageFixtures.keypair()
      Crew.ImageFixtures.trust(key)
      dir = Crew.AgentReleaseFixtures.tmp_dir("ignition-releases")
      Crew.AgentReleaseFixtures.write_release(dir, key, "0.3.0", "linux-arm64")
      Crew.Agents.Releases.register_bundle(dir)
      admin = Crew.Scope.for_user(user_fixture(role: "admin"))

      {:ok, token} =
        Crew.Boxes.create_join_token(admin, %{"box_name" => "m3max", "box_type" => "mac-vm"})

      %{flatcar_token: token}
    end

    test "returns the box's Ignition, named in X-Crew-Box", %{conn: conn, flatcar_token: token} do
      conn =
        post(conn, "/agent/flatcar/ignition", %{
          "join_token" => token,
          "arch" => "arm64",
          "ssh_keys" => ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyForCore crew-box@host"]
        })

      assert %{"ignition" => %{"version" => "3.4.0"}} = json_response(conn, 200)
      assert get_resp_header(conn, "x-crew-box") == ["m3max"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="crew-m3max-arm64.ign")
             ]
    end

    test "the token still enrolls the agent afterwards", %{
      conn: conn,
      flatcar_token: token,
      key: key
    } do
      assert post(conn, "/agent/flatcar/ignition", %{"join_token" => token, "arch" => "arm64"}).status ==
               200

      conn =
        post(build_conn(), ~p"/api/agents/enroll", %{"join_token" => token, "public_key" => key})

      assert json_response(conn, 201)["box"] == "m3max"

      conn =
        post(build_conn(), "/agent/flatcar/ignition", %{"join_token" => token, "arch" => "arm64"})

      assert json_response(conn, 401)["error"] =~ "invalid"
    end

    test "a bad arch or SSH key is a 400 that says why", %{conn: conn, flatcar_token: token} do
      conn = post(conn, "/agent/flatcar/ignition", %{"join_token" => token, "arch" => "x86_64"})
      assert json_response(conn, 400)["error"] =~ "amd64"

      conn =
        post(build_conn(), "/agent/flatcar/ignition", %{
          "join_token" => token,
          "arch" => "arm64",
          "ssh_keys" => ["nope"]
        })

      assert json_response(conn, 400)["error"] =~ "SSH"
    end

    test "no release for the arch is a 503 that says why", %{conn: conn, flatcar_token: token} do
      conn = post(conn, "/agent/flatcar/ignition", %{"join_token" => token, "arch" => "amd64"})
      assert json_response(conn, 503)["error"] =~ "linux-amd64"
    end

    test "a mac-vz box's token doesn't get one", %{conn: conn, token: vz_token} do
      conn = post(conn, "/agent/flatcar/ignition", %{"join_token" => vz_token, "arch" => "arm64"})
      assert json_response(conn, 400)["error"] =~ "mac-vz"
    end

    test "bad tokens count against the enrollment limit" do
      ip = "100.65.#{:rand.uniform(250)}.#{:rand.uniform(250)}"

      req = fn path, body ->
        build_conn()
        |> put_req_header("x-forwarded-for", ip)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> post(path, body)
      end

      for _ <- 1..5,
          do:
            assert(
              req.("/agent/flatcar/ignition", %{"join_token" => "cj_no", "arch" => "arm64"}).status ==
                401
            )

      for _ <- 1..5,
          do:
            assert(
              req.(~p"/api/agents/enroll", %{"join_token" => "cj_no", "public_key" => "x"}).status ==
                401
            )

      assert req.("/agent/flatcar/ignition", %{"join_token" => "cj_no", "arch" => "arm64"}).status ==
               429
    end
  end

  test "serves the launchers, filled in", %{conn: conn} do
    for type <- ["linux-vm", "mac-vm"] do
      conn = get(conn, "/agent/#{type}.sh")
      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/x-shellscript"
      assert conn.resp_body =~ ~s(CREW_URL="#{Crew.Config.base_url()}")
      refute conn.resp_body =~ "__FLATCAR_VERSION__"
    end
  end

  describe "agent release tarballs" do
    setup do
      key = Crew.ImageFixtures.keypair()
      Crew.ImageFixtures.trust(key)
      dir = Crew.AgentReleaseFixtures.tmp_dir("served-releases")
      files = Crew.AgentReleaseFixtures.write_release(dir, key, "0.3.0", "linux-amd64")
      Crew.Agents.Releases.register_bundle(dir)
      %{files: files}
    end

    test "are served with their digest and signature", %{conn: conn, files: files} do
      conn = get(conn, "/agent/releases/0.3.0/linux-amd64/crew-agent-0.3.0-linux-amd64.tar.gz")

      assert conn.status == 200
      assert conn.resp_body == files["agent"].bytes
      assert get_resp_header(conn, "x-crew-sha256") == [files["agent"].sha256]
      assert get_resp_header(conn, "x-crew-signature") == [files["agent"].signature]
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/gzip"
    end

    test "with their .sha256 and .sig beside them", %{conn: conn, files: files} do
      base = "/agent/releases/0.3.0/linux-amd64/crew-cache-0.3.0-linux-amd64.tar.gz"

      assert get(conn, base <> ".sha256").resp_body ==
               "#{files["cache"].sha256}  crew-cache-0.3.0-linux-amd64.tar.gz\n"

      assert get(build_conn(), base <> ".sig").resp_body == files["cache"].signature
    end

    test "anything else is a 404", %{conn: conn} do
      for path <- [
            "/agent/releases/0.3.0/linux-amd64/crew-agent-0.3.0-linux-arm64.tar.gz",
            "/agent/releases/0.3.0/linux-arm64/crew-agent-0.3.0-linux-arm64.tar.gz",
            "/agent/releases/0.4.0/linux-amd64/crew-agent-0.4.0-linux-amd64.tar.gz",
            "/agent/releases/0.3.0/linux-amd64/crew-guest-0.3.0-linux-amd64.tar.gz",
            "/agent/releases/0.3.0/linux-amd64/..%2F..%2Fetc%2Fpasswd"
          ] do
        assert get(conn, path).status == 404, path
      end
    end
  end
end
