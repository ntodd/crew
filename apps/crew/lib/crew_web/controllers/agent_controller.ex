defmodule CrewWeb.AgentController do
  @moduledoc """
  What boxes fetch over plain HTTP before they have an identity (Foreman's):
  enrollment (§10.2) and the agent release tarballs (§20.1). Enrollment
  takes a join token, and a bad one counts against the client's limit;
  tarballs are signed, and boxes check the signature themselves.
  """
  use CrewWeb, :controller

  alias Crew.Agents.Releases
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

  @doc """
  A registered release file: the tarball, or its `.sha256` or `.sig`.
  Only in development do boxes download from here (`Releases.url/1`);
  the control plane serves what it holds either way, as Foreman's does.
  """
  def release(conn, %{"version" => version, "target" => target, "file" => file}) do
    {tarball, suffix} =
      case Path.extname(file) do
        ext when ext in [".sha256", ".sig"] -> {Path.rootname(file), ext}
        _ -> {file, ""}
      end

    with {component, ^version, ^target} <- Releases.parse_file_name(tarball),
         %{path: path} = release <- Releases.get(component, version, target),
         true <- File.regular?(path) do
      send_release(conn, release, tarball, suffix)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such release file"})
    end
  end

  defp send_release(conn, release, tarball, ".sha256"),
    do: text(conn, "#{release.sha256}  #{tarball}\n")

  defp send_release(conn, release, _tarball, ".sig"), do: text(conn, release.signature)

  # sobelow_skip ["Traversal.SendFile"]
  # The path is the release row's, which only registration writes; the
  # params only pick the row (matched for equality above).
  defp send_release(conn, release, _tarball, "") do
    conn
    |> put_resp_content_type("application/gzip", nil)
    |> put_resp_header("x-crew-version", release.version)
    |> put_resp_header("x-crew-sha256", release.sha256)
    |> put_resp_header("x-crew-signature", release.signature)
    |> send_file(200, release.path)
  end

  defp count_failure({:ok, _} = ok, _key), do: ok

  defp count_failure(error, key) do
    RateLimit.failed(key, @window, @max_failures)
    error
  end
end
