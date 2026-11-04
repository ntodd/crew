defmodule Crew.Images.Runner do
  @moduledoc """
  Runner version freshness (§13.1). GitHub stops giving jobs to runners
  too far behind the latest `actions/runner` release, so the control
  plane checks the releases daily, and the Images page warns once an
  image's runner has been behind for 14 days and alerts at 21. Behind
  counts from the first release after the image's runner.
  """
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias Crew.GitHub.Client
  alias Crew.Settings

  @key "runner_releases"
  @warn_days 14
  @alert_days 21

  @impl true
  def perform(_job) do
    case Req.get(Client.api(), url: "/repos/actions/runner/releases", params: [per_page: 30]) do
      {:ok, %{status: 200, body: list}} when is_list(list) ->
        releases =
          for %{"tag_name" => "v" <> version, "published_at" => at} = r <- list,
              r["draft"] != true and r["prerelease"] != true,
              match?({:ok, _}, Version.parse(version)),
              do: %{"version" => version, "published_at" => at}

        Settings.put(@key, releases)

      {:ok, %{status: status}} ->
        Logger.warning("checking actions/runner's releases got HTTP #{status}")
        {:error, "HTTP #{status}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  @doc "The releases from the last check, newest first."
  def releases, do: Settings.get(@key, [])

  @doc """
  How far `version` is behind: days since the first release after it,
  the latest release, and `:ok`, `:warn` (14 days) or `:alert` (21). Nil
  without releases to compare, or for a version that isn't one.
  """
  def freshness(version, releases \\ releases(), now \\ DateTime.utc_now())

  def freshness(_version, [], _now), do: nil

  def freshness(version, releases, now) do
    case Version.parse(version || "") do
      {:ok, current} -> behind(current, releases, now)
      :error -> nil
    end
  end

  defp behind(current, releases, now) do
    newer =
      for r <- releases,
          {:ok, v} <- [Version.parse(r["version"])],
          Version.compare(v, current) == :gt,
          {:ok, at, _} <- [DateTime.from_iso8601(r["published_at"])],
          do: {v, at}

    days =
      case Enum.min_by(newer, fn {v, _} -> v end, Version, fn -> nil end) do
        nil -> 0
        {_, at} -> max(0, div(DateTime.diff(now, at), 86_400))
      end

    latest = releases |> Enum.map(& &1["version"]) |> Enum.max_by(&Version.parse!/1, Version)
    %{days: days, latest: latest, level: level(days)}
  end

  defp level(days) when days >= @alert_days, do: :alert
  defp level(days) when days >= @warn_days, do: :warn
  defp level(_), do: :ok
end
