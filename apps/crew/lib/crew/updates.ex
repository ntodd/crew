defmodule Crew.Updates do
  @moduledoc """
  New Crew releases, and updating to them from the Deployment page
  (§20.3). Foreman's `Updates` for Crew.

  `check/0` asks GitHub for the highest published `vX.Y.Z` release of
  CREW_UPDATE_REPO and keeps it in the settings table;
  `Crew.Updates.Check` runs it daily (CREW_UPDATE_CHECK=false turns that
  off), and at boot when there's no check yet.

  The control plane can't replace its own container, so updating is the
  host's job: `crew-update` (docker/crew-update), run by a systemd path
  unit as root. The two share a directory (CREW_UPDATE_DIR, mounted into
  the container):

    * `request/` is the container's. `request/2` writes the version to
      `request/version`, and that is all the container can say: the host
      takes a newer `X.Y.Z` from the repository of the image it runs, or
      nothing.
    * `status/` is the host's, read-only in here: `updater` exists once
      the updater is installed, and `state.json` describes its last run.
  """

  require Logger

  alias Crew.{Audit, Scope, Settings}
  alias Crew.GitHub.Client

  @key "update_latest"
  # What crew-update's is_version takes: X.Y.Z, at most four digits each,
  # no leading zeros. A release it would refuse is never offered.
  @tag ~r/\Av((?:0|[1-9]\d{0,3})\.(?:0|[1-9]\d{0,3})\.(?:0|[1-9]\d{0,3}))\z/
  # The updater reports at least every step; a run silent this long died.
  @stale_after 30 * 60

  def enabled?, do: Application.get_env(:crew, :update_check, true) == true

  def repo, do: Application.get_env(:crew, :update_repo, "ntodd/crew")

  @doc """
  The highest published release as last checked:
  `%{version:, url:, checked_at:, error:}`, with `version` nil when the
  repo had none, or nil before the first check.
  """
  def latest do
    case Settings.get(@key) do
      %{} = m ->
        %{
          version: m["version"],
          url: m["url"],
          checked_at: parse_time(m["checked_at"]),
          error: m["error"]
        }

      _ ->
        nil
    end
  end

  @doc "The latest release if it's newer than this control plane, or nil."
  def available do
    case latest() do
      %{version: version} = release when is_binary(version) ->
        if newer?(version, Crew.Config.version()), do: release

      _ ->
        nil
    end
  end

  def newer?(a, b) do
    with {:ok, a} <- Version.parse(a),
         {:ok, b} <- Version.parse(b) do
      Version.compare(a, b) == :gt
    else
      _ -> false
    end
  end

  @doc "Asks GitHub for the latest release and keeps it."
  def check do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case fetch_releases() do
      {:ok, releases} ->
        release =
          releases
          |> Enum.flat_map(&published/1)
          |> Enum.max_by(&Version.parse!(&1.version), Version, fn -> nil end)

        Settings.put(@key, %{
          "version" => release && release.version,
          "url" => release && release.url,
          "checked_at" => now,
          "error" => nil
        })

        {:ok, release}

      {:error, reason} ->
        message = error_message(reason)
        Logger.warning("couldn't check #{repo()} for Crew releases: #{message}")
        last = Settings.get(@key) || %{}
        Settings.put(@key, Map.merge(last, %{"checked_at" => now, "error" => message}))
        {:error, reason}
    end
  end

  defp fetch_releases do
    case Req.get(Client.api(), url: "/repos/#{repo()}/releases", params: [per_page: 30]) do
      {:ok, %{status: 200, body: releases}} when is_list(releases) -> {:ok, releases}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp published(%{"draft" => false, "prerelease" => false, "tag_name" => tag} = release)
       when is_binary(tag) do
    case Regex.run(@tag, tag) do
      [_, version] -> [%{version: version, url: release["html_url"]}]
      nil -> []
    end
  end

  defp published(_), do: []

  defp error_message({:status, status}), do: "GitHub answered #{status}"
  defp error_message(%{__exception__: true} = e), do: Exception.message(e)
  defp error_message(other), do: inspect(other)

  @doc """
  Estimates SQLite upgrade downtime from the uncompressed files the host updater
  archives. The range allows for compression, archive verification and startup.
  """
  def backup_estimate do
    root = Application.get_env(:crew, :update_data_dir, "/var/lib/crew")
    # docker/crew-update archives this mount with tar --exclude='./images'.
    bytes = Enum.sum_by(File.ls!(root) -- ["images"], &backup_bytes(Path.join(root, &1)))

    # The 0.2.1 upgrade processed roughly 3 GiB in six minutes. Use a broad
    # range (6–20 MiB/s including verification), plus time to stop and boot.
    mib = bytes / (1024 * 1024)

    %{
      bytes: bytes,
      min_minutes: ceil((mib / 20 + 15) / 60),
      max_minutes: ceil((mib / 6 + 60) / 60)
    }
  rescue
    File.Error -> :unavailable
  end

  defp backup_bytes(path) do
    case File.lstat!(path, time: :posix) do
      %{type: :regular, size: bytes} -> bytes
      %{type: :directory} -> Enum.sum_by(File.ls!(path), &backup_bytes(Path.join(path, &1)))
      _ -> 0
    end
  rescue
    # A log can be pruned while the dashboard is measuring the live volume.
    error in File.Error ->
      if error.reason == :enoent, do: 0, else: reraise(error, __STACKTRACE__)
  end

  @doc """
  The host's updater: whether it's installed, and its last run, if any.
  A request it hasn't picked up yet shows as `"pending"`, and a run that
  stopped reporting as `"stale"`.
  """
  def updater do
    status = Path.join(dir(), "status")

    if File.regular?(Path.join(status, "updater")) do
      Map.merge(%{installed: true}, run(status))
    else
      %{installed: false, state: nil}
    end
  end

  defp run(status) do
    case requested() do
      nil -> last_run(status)
      version -> %{state: "pending", to: version, from: nil, message: nil, at: nil}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Every path is under update_dir, from the deployment's config; nothing
  # a request sends reaches one.
  defp last_run(status) do
    with {:ok, body} <- File.read(Path.join(status, "state.json")),
         {:ok, %{} = state} <- JSON.decode(body) do
      at = parse_time(state["at"])

      %{
        state: stale(state["state"], at),
        from: state["from"],
        to: state["to"],
        message: state["message"],
        at: at
      }
    else
      _ -> %{state: nil, from: nil, to: nil, message: nil, at: nil}
    end
  end

  defp stale("running", at) do
    if at && DateTime.diff(DateTime.utc_now(), at) < @stale_after, do: "running", else: "stale"
  end

  defp stale(state, _at), do: state

  defp parse_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  # sobelow_skip ["Traversal.FileModule"]
  # Every path is under update_dir, from the deployment's config; nothing
  # a request sends reaches one.
  defp requested do
    case File.read(request_path()) do
      {:ok, body} -> String.trim(body)
      _ -> nil
    end
  end

  @doc """
  Asks the host to update to `version`, which must be the release the
  last check found newer than this one. Admins only; audited.
  """
  def request(%Scope{} = scope, version) do
    cond do
      not Scope.admin?(scope) -> {:error, :forbidden}
      not match?(%{version: ^version}, available()) -> {:error, :not_available}
      not updater().installed -> {:error, :no_updater}
      updater().state in ["pending", "running"] -> {:error, :in_progress}
      true -> write_request(scope, version)
    end
  end

  # Renamed into place, so the host never reads half a version. The path
  # unit only watches `version`.
  # sobelow_skip ["Traversal.FileModule"]
  # Every path is under update_dir, from the deployment's config; the
  # version is the one the last check found, never a request's.
  defp write_request(scope, version) do
    tmp = Path.join(Path.dirname(request_path()), ".version.tmp")

    with :ok <- File.write(tmp, version <> "\n"),
         :ok <- File.rename(tmp, request_path()) do
      Audit.log(scope, "crew.update", nil, %{"from" => Crew.Config.version(), "to" => version})
      :ok
    end
  end

  defp dir, do: Application.get_env(:crew, :update_dir, "/var/lib/crew-update")
  defp request_path, do: Path.join([dir(), "request", "version"])
end
