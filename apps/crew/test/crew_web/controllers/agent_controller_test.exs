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
