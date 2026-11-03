defmodule Crew.GitHub.Redeliver do
  @moduledoc """
  Missed deliveries (§6.2): GitHub doesn't redeliver on its own. Every
  5 minutes, and at boot, this lists the App's deliveries back to the
  newest one Crew processed (at most 3 days), and asks GitHub to deliver
  again each failed one Crew never recorded. The reconciler covers
  anything that still slips through.
  """
  use Oban.Worker, queue: :reconcile, max_attempts: 1, unique: [period: 240]

  import Ecto.Query

  require Logger

  alias Crew.GitHub.{Client, Delivery}
  alias Crew.Repo

  @max_age_s 3 * 86_400
  @max_pages 20

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
      app -> with {:ok, deliveries} <- collect(app, nil, [], 1), do: redeliver(app, deliveries)
    end
  end

  defp collect(_app, _cursor, acc, page) when page > @max_pages, do: {:ok, acc}

  defp collect(app, cursor, acc, page) do
    with {:ok, items, next} <- Client.list_hook_deliveries(app, cursor) do
      cutoff = DateTime.add(DateTime.utc_now(), -@max_age_s)
      {kept, stop?} = take_until_processed(items, cutoff)
      acc = acc ++ kept

      if stop? or is_nil(next), do: {:ok, acc}, else: collect(app, next, acc, page + 1)
    end
  end

  # Newest first: keep going until a delivery Crew processed, or one too old.
  defp take_until_processed(items, cutoff) do
    guids = items |> Enum.map(& &1["guid"]) |> Enum.reject(&is_nil/1)

    processed =
      Repo.all(
        from d in Delivery,
          where: d.github_delivery_id in ^guids and not is_nil(d.processed_at),
          select: d.github_delivery_id
      )
      |> MapSet.new()

    Enum.reduce_while(items, {[], false}, fn item, {acc, _} ->
      cond do
        MapSet.member?(processed, item["guid"]) -> {:halt, {acc, true}}
        too_old?(item, cutoff) -> {:halt, {acc, true}}
        true -> {:cont, {[item | acc], false}}
      end
    end)
    |> then(fn {acc, stop?} -> {Enum.reverse(acc), stop?} end)
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

    {:ok, count}
  end

  defp ok?(%{"status_code" => code}) when is_integer(code), do: code in 200..299
  defp ok?(_), do: false
end
