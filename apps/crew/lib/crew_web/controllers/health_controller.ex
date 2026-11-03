defmodule CrewWeb.HealthController do
  @moduledoc """
  `GET /healthz` for systemd, Docker and load balancer health checks: 200
  when the app is up and its database answers, 503 when it doesn't.
  Unauthenticated, and says nothing beyond that.
  """
  use CrewWeb, :controller

  require Logger

  def show(conn, _params) do
    {status, body} =
      case Ecto.Adapters.SQL.query(Crew.Repo, "SELECT 1", [], timeout: 2_000) do
        {:ok, _} ->
          {200, "ok"}

        {:error, error} ->
          Logger.warning("health check: database unavailable: #{Exception.message(error)}")
          {503, "database unavailable"}
      end

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
  end
end
