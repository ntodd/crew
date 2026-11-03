defmodule CrewWeb.HookEndpoint do
  @moduledoc """
  GitHub's way in (§6.2): its own listener on
  `127.0.0.1:${CREW_HOOK_PORT}`, exposed through Tailscale Funnel on
  8443, with exactly one route, `POST /hooks/github`. No sessions,
  LiveView, static files or other plugs.

  Handling, in order:
  1. Refuse bodies over 5 MiB (413) before reading them.
  2. Verify `X-Hub-Signature-256`. On failure, 401; failures are
     rate-limited per client (60 a minute), correctly signed requests
     never are.
  3. Record the delivery id. Seen before: 200, and stop.
  4. Queue `Crew.GitHub.HookWorker` with the event, action and payload.
  5. 202: GitHub's 10-second timeout never waits on processing.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Crew.GitHub.{HookWorker, Webhook}

  @max_body 5 * 1024 * 1024
  @fail_window 60_000
  @fail_limit 60

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["hooks", "github"]} = conn, _opts) do
    with :ok <- check_length(conn),
         {:ok, body, conn} <- read_limited(conn),
         :ok <- verify(conn, body),
         {:ok, delivery, event} <- headers(conn),
         {:ok, payload} <- decode(body) do
      accept(conn, delivery, event, payload)
    else
      {:halt, conn, status} -> respond(conn, status)
      {:halt, status} -> respond(conn, status)
    end
  end

  def call(conn, _opts), do: respond(conn, 404)

  defp check_length(conn) do
    case get_req_header(conn, "content-length") do
      [len] ->
        case Integer.parse(len) do
          {n, ""} when n > @max_body -> {:halt, 413}
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  # Without a content-length (chunked), read one byte past the cap.
  defp read_limited(conn) do
    case read_body(conn, length: @max_body + 1, read_length: 1_000_000, read_timeout: 15_000) do
      {:ok, body, conn} when byte_size(body) <= @max_body -> {:ok, body, conn}
      {:ok, _body, conn} -> {:halt, conn, 413}
      {:more, _partial, conn} -> {:halt, conn, 413}
      {:error, _} -> {:halt, 400}
    end
  end

  defp verify(conn, body) do
    signature = conn |> get_req_header("x-hub-signature-256") |> List.first()

    case Webhook.verify(body, signature, Crew.GitHub.webhook_secret()) do
      :ok ->
        :ok

      :error ->
        key = "hooks:" <> CrewWeb.ClientIP.from_conn(conn)

        if Crew.RateLimit.exhausted?(key, @fail_window, @fail_limit) do
          {:halt, 429}
        else
          if Crew.RateLimit.failed(key, @fail_window, @fail_limit) == :first_over,
            do: Logger.warning("webhook signature failures from #{key} are being rate limited")

          {:halt, 401}
        end
    end
  end

  defp headers(conn) do
    with [delivery] when byte_size(delivery) in 1..64 <- get_req_header(conn, "x-github-delivery"),
         [event] when byte_size(event) in 1..64 <- get_req_header(conn, "x-github-event") do
      {:ok, delivery, event}
    else
      _ -> {:halt, 400}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = payload} -> {:ok, payload}
      _ -> {:halt, 400}
    end
  end

  defp accept(conn, delivery, event, payload) do
    action = if is_binary(payload["action"]), do: String.slice(payload["action"], 0, 64)

    case HookWorker.record(delivery, event, action, payload) do
      :new -> respond(conn, 202)
      :duplicate -> respond(conn, 200)
    end
  end

  defp respond(conn, status) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, Plug.Conn.Status.reason_phrase(status))
    |> halt()
  end
end
