defmodule Crew.GitHub.Redeliver do
  @moduledoc """
  Missed deliveries (§6.2): GitHub doesn't redeliver on its own. Every
  5 minutes, and at boot, this lists the App's deliveries back to the
  previous scan with an overlap (at most 3 days), and asks GitHub to deliver
  again each failed one Crew never recorded. The reconciler covers
  anything that still slips through.
  """
  use Oban.Worker,
    queue: :reconcile,
    max_attempts: 1,
    unique: [period: 240, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query

  require Logger

  alias Crew.GitHub.{Client, Delivery}
  alias Crew.{Repo, Settings}

  @max_age_s 3 * 86_400
  @max_pages 20
  @overlap_s 600

  @impl true
  def perform(_job) do
    case run() do
      {:ok, _} -> :ok
      {:error, :not_configured} -> :ok
      error -> error
    end
  end

  @doc "Redelivers what Crew missed. `{:ok, count}`."
  def run do
    case Crew.GitHub.app() do
      nil -> {:error, :not_configured}
      app -> scan(app)
    end
  end

  defp scan(app) do
    now = System.system_time(:second)
    key = "redelivery_scan_#{app.app_id}"
    state = Settings.get(key, %{})
    started = state["started"] || now
    since = max(now - @max_age_s, (state["last_scan"] || 0) - @overlap_s)
    cutoff = DateTime.from_unix!(since)

    with {:ok, items, next} <- collect(app, state["cursor"], cutoff, [], 1),
         {:ok, count} <- redeliver(app, items) do
      checkpoint =
        if next do
          Map.merge(state, %{"cursor" => next, "started" => started})
        else
          %{"last_scan" => started}
        end

      Settings.put(key, checkpoint)
      {:ok, count}
    end
  end

  defp collect(app, cursor, cutoff, acc, page) do
    with {:ok, items, next} <- Client.list_hook_deliveries(app, cursor) do
      kept = Enum.take_while(items, &(not too_old?(&1, cutoff)))
      acc = acc ++ kept

      cond do
        length(kept) < length(items) or is_nil(next) -> {:ok, acc, nil}
        page == @max_pages -> {:ok, acc, next}
        true -> collect(app, next, cutoff, acc, page + 1)
      end
    end
  end

  defp too_old?(%{"delivered_at" => at}, cutoff) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :lt
      _ -> false
    end
  end

  defp too_old?(_item, _cutoff), do: false

  defp redeliver(app, deliveries) do
    by_guid = Enum.group_by(deliveries, & &1["guid"])

    recorded =
      Repo.all(
        from d in Delivery,
          where: d.github_delivery_id in ^Map.keys(by_guid),
          select: d.github_delivery_id
      )
      |> MapSet.new()

    # A guid is missed if no attempt of it succeeded and Crew never saw it.
    missed =
      for {guid, attempts} <- by_guid,
          not MapSet.member?(recorded, guid),
          not Enum.any?(attempts, &ok?/1),
          do: Enum.max_by(attempts, & &1["id"])

    count =
      Enum.count(missed, fn delivery ->
        case Client.redeliver(app, delivery["id"]) do
          :ok ->
            true

          error ->
            Logger.warning("couldn't redeliver #{delivery["guid"]}: #{inspect(error)}")
            false
        end
      end)

    if count == length(missed), do: {:ok, count}, else: {:error, :redelivery_failed}
  end

  defp ok?(%{"status_code" => code}) when is_integer(code), do: code in 200..299
  defp ok?(_), do: false
end
