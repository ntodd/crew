defmodule CrewWeb.AgentController do
  @moduledoc "Agent enrollment (§10.2, Foreman's). A bad token counts against the client's limit."
  use CrewWeb, :controller

  alias Crew.{Boxes, RateLimit}

  @window 60_000
  @max_failures 10

  def enroll(conn, params) do
    key = "enroll-failed:#{CrewWeb.ClientIP.from_conn(conn)}"

    with false <- RateLimit.exhausted?(key, @window, @max_failures),
         {:ok, box} <- count_failure(Boxes.enroll(params["join_token"], params), key) do
      conn |> put_status(:created) |> json(%{agent_id: box.id, box: box.name, type: box.type})
    else
      true ->
        conn |> put_status(:too_many_requests) |> json(%{error: "too many attempts"})

      {:error, :bad_key} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "public_key must be a base64 ed25519 key"})

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "join token is invalid, expired or used"})
    end
  end

  defp count_failure({:ok, _} = ok, _key), do: ok

  defp count_failure(error, key) do
    RateLimit.failed(key, @window, @max_failures)
    error
  end
end
