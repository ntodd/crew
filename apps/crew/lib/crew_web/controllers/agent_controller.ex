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

  @doc "The linux-vm launcher (§12.3)."
  def linux_vm_script(conn, _params), do: send_launcher(conn, "linux-vm")

  @doc "The mac-vm launcher (§12.3)."
  def mac_vm_script(conn, _params), do: send_launcher(conn, "mac-vm")

  defp send_launcher(conn, type) do
    case Crew.Boxes.Launcher.script(type, Crew.Config.base_url()) do
      {:ok, script} ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(200, script)

      {:error, :bad_url} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "the control plane's URL (CREW_BASE_URL) can't go in a launcher"})
    end
  end

  @doc """
  A Flatcar box's first-boot Ignition for a join token (§12.2, Foreman's):
  `join_token`, `arch` and optional `ssh_keys[]`, answered with the box's
  name in `X-Crew-Box`. It carries the token, so a bad one counts against
  the client like a failed enrollment; a good one stays good for the
  agent's own enrollment.
  """
  def flatcar_ignition(conn, params) do
    key = "enroll-failed:#{CrewWeb.ClientIP.from_conn(conn)}"

    with false <- RateLimit.exhausted?(key, @window, @max_failures),
         {:ok, config, name} <- Boxes.flatcar_ignition(params["join_token"], params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-crew-box", name)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="crew-#{name}-#{params["arch"]}.ign")
      )
      |> json(config)
    else
      true ->
        conn |> put_status(:too_many_requests) |> json(%{error: "too many attempts"})

      {:error, :invalid_token} ->
        RateLimit.failed(key, @window, @max_failures)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "join token is invalid, expired or used"})

      {:error, reason} ->
        {status, message} = ignition_error(reason, params)
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  @doc """
  A `mac-vz` box's cache VM's first-boot Ignition (§12.3, §15.6), for its
  join token and optional `ssh_keys[]`: the box's name in `X-Crew-Box`,
  and in `X-Crew-Cache-Token` the management token the Ignition carries,
  for the box's agent. Bad tokens count as `flatcar_ignition/2`'s do.
  """
  def cachevm_ignition(conn, params) do
    key = "enroll-failed:#{CrewWeb.ClientIP.from_conn(conn)}"

    with false <- RateLimit.exhausted?(key, @window, @max_failures),
         {:ok, config, name, mgmt_token} <- Boxes.cachevm_ignition(params["join_token"], params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-crew-box", name)
      |> put_resp_header("x-crew-cache-token", mgmt_token)
      |> json(config)
    else
      true ->
        conn |> put_status(:too_many_requests) |> json(%{error: "too many attempts"})

      {:error, :invalid_token} ->
        RateLimit.failed(key, @window, @max_failures)

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "join token is invalid, expired or used"})

      {:error, :not_mac_vz} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "only a mac-vz box has a cache VM; this token is for another type"})

      {:error, reason} ->
        {status, message} = ignition_error(reason, %{"arch" => "arm64"})
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  defp ignition_error(:bad_arch, _),
    do: {:bad_request, "arch must be one of: #{Enum.join(Crew.Boxes.Flatcar.arches(), ", ")}"}

  defp ignition_error(:bad_ssh_key, _), do: {:bad_request, "ssh_keys must be SSH public keys"}

  defp ignition_error(:not_flatcar, _),
    do:
      {:bad_request,
       "this join token is for a mac-vz box, which doesn't run Flatcar; its Add box page has the steps"}

  defp ignition_error(:no_release, params),
    do:
      {:service_unavailable,
       "no agent release for #{Crew.Boxes.Flatcar.target(params["arch"])} is registered (CREW_AGENT_RELEASE_DIR)"}

  defp ignition_error(:no_release_key, _),
    do: {:service_unavailable, "no release key is configured (CREW_RELEASE_PUBLIC_KEY)"}

  defp ignition_error({:tailscale, reason}, _),
    do: {:bad_gateway, "Tailscale wouldn't mint the box a key: #{inspect(reason)}"}

  defp ignition_error(reason, _), do: {:bad_request, "can't make this box's Ignition: #{reason}"}

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
