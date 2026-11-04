defmodule CrewWeb.BoxControllerTest do
  @moduledoc "The reprovision Ignition, downloaded from the box page (§12.2)."
  use CrewWeb.ConnCase

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")
    scope = Crew.Scope.for_user(admin)

    {:ok, raw} =
      Crew.Boxes.create_join_token(scope, %{"box_name" => "m3max", "box_type" => "mac-vm"})

    {public, _} = CrewProtocol.Auth.generate_keypair()
    {:ok, box} = Crew.Boxes.enroll(raw, %{"public_key" => Base.encode64(public)})
    %{conn: log_in(conn, admin), box: box}
  end

  test "an admin downloads it", %{conn: conn, box: box} do
    conn = get(conn, ~p"/boxes/#{box.id}/reprovision.ign?arch=arm64")
    assert %{"ignition" => %{"version" => "3.4.0"}} = config = json_response(conn, 200)

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="crew-m3max-arm64-reprovision.ign")
           ]

    refute Enum.any?(config["storage"]["files"], &(&1["path"] == "/etc/crew-box/provision.env"))

    assert Crew.Repo.get_by(Crew.Audit.Event, action: "box.reprovision_ignition").subject_id ==
             box.id
  end

  test "a bad arch is a 400", %{conn: conn, box: box} do
    assert get(conn, ~p"/boxes/#{box.id}/reprovision.ign?arch=mips").status == 400
  end

  test "members can't", %{box: box} do
    conn = log_in(build_conn(), user_fixture())
    assert get(conn, ~p"/boxes/#{box.id}/reprovision.ign?arch=arm64").status == 404
  end
end
