defmodule CrewWeb.StaleAssetsTest do
  # Changes the endpoint's static manifest, which every test shares.
  use CrewWeb.ConnCase, async: false

  setup :register_and_log_in

  setup do
    endpoint = CrewWeb.Endpoint
    before = endpoint.config(:cache_static_manifest_latest)

    Phoenix.Config.put(endpoint, :cache_static_manifest_latest, %{
      "assets/css/app.css" => "assets/css/app-new.css"
    })

    on_exit(fn -> Phoenix.Config.put(endpoint, :cache_static_manifest_latest, before) end)
  end

  defp tracking(conn, asset),
    do: put_connect_params(conn, %{"_track_static" => ["http://localhost/#{asset}?vsn=d"]})

  test "a page built from older assets reloads, keeping its URL", %{conn: conn} do
    conn = tracking(conn, "assets/css/app-old.css")

    assert {:error, {:redirect, %{to: "/?range=1d"}}} = live(conn, "/?range=1d")
  end

  test "a page built from the current assets stays", %{conn: conn} do
    conn = tracking(conn, "assets/css/app-new.css")

    assert {:ok, _view, _html} = live(conn, "/")
  end
end
