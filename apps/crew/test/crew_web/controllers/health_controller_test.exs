defmodule CrewWeb.HealthControllerTest do
  use CrewWeb.ConnCase

  test "GET /healthz answers without signing in, after checking the database", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "health checks aren't logged, everything else is" do
    assert CrewWeb.Endpoint.log_level(Phoenix.ConnTest.build_conn(:get, "/healthz")) == false
    assert CrewWeb.Endpoint.log_level(Phoenix.ConnTest.build_conn(:get, "/admin")) == :info
  end
end
