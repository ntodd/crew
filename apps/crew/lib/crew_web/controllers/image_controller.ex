defmodule CrewWeb.ImageController do
  @moduledoc """
  An image's kernel and compressed root filesystem, for boxes to
  download (§13.1). They're a public release's files, signed, and the
  agent checks them against the signed manifest itself, so as with
  Foreman's agent releases no credentials are asked for. A `Range`
  request resumes a download.
  """
  use CrewWeb, :controller

  alias Crew.Images

  # The paths come from the image's row, written by the mirror; the
  # params only pick the row and which of its two files.
  def show(conn, %{"id" => id, "file" => file}) when file in ["kernel", "rootfs"] do
    with true <- CrewProtocol.uuid?(id),
         %{mirror_state: "ready"} = image <- Images.get(id),
         {path, sha} when is_binary(path) <- pick(image, file),
         {:ok, %{size: size}} <- File.stat(path) do
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("x-crew-sha256", sha)
      |> put_resp_header("accept-ranges", "bytes")
      |> send_range(path, size)
    else
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp pick(image, "kernel"), do: {image.kernel_path, image.kernel_sha256}
  defp pick(image, "rootfs"), do: {image.rootfs_path, image.rootfs_sha256}

  # sobelow_skip ["Traversal.SendFile"]
  # `path` is the image row's, never a param (show/2).
  defp send_range(conn, path, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        case range(spec, size) do
          {from, to} ->
            conn
            |> put_resp_header("content-range", "bytes #{from}-#{to}/#{size}")
            |> send_file(206, path, from, to - from + 1)

          :error ->
            conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")
        end

      _ ->
        send_file(conn, 200, path)
    end
  end

  # One range, "N-" or "N-M"; anything else isn't satisfiable.
  defp range(spec, size) do
    case String.split(spec, "-", parts: 2) do
      [from, to] ->
        with {f, ""} when f >= 0 and f < size <- Integer.parse(from),
             {:ok, t} <- range_end(to, size),
             true <- t >= f do
          {f, t}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp range_end("", size), do: {:ok, size - 1}

  defp range_end(to, size) do
    case Integer.parse(to) do
      {t, ""} -> {:ok, min(t, size - 1)}
      _ -> :error
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "no such image file"})
end
