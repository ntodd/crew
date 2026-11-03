defmodule Crew.GitHub.HookHealth do
  @moduledoc "Webhook health for the Deployment page (§17.3)."
  import Ecto.Query

  alias Crew.GitHub.{Client, Delivery}
  alias Crew.{Repo, Settings}

  def summary do
    since = DateTime.add(DateTime.utc_now(), -86_400)

    %{
      last_received_at: Repo.one(from d in Delivery, select: max(d.received_at)),
      failed_24h:
        Repo.aggregate(
          from(d in Delivery, where: d.received_at > ^since and not is_nil(d.error)),
          :count
        ),
      last_ping_at:
        case Settings.get("webhook_ping") do
          %{"at" => at} -> parse(at)
          _ -> nil
        end
    }
  end

  defp parse(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc """
  GitHub has no API to ping an App's webhook, so this asks it to deliver
  the most recent ping again: the one it sent when the App was created.
  """
  def send_ping do
    with app when is_map(app) <- Crew.GitHub.app() || {:error, "The GitHub App isn't set up."},
         {:ok, items, _} <- Client.list_hook_deliveries(app),
         %{"id" => id} <-
           Enum.find(items, &(&1["event"] == "ping")) ||
             {:error, "GitHub has no ping delivery to send again."} do
      case Client.redeliver(app, id) do
        :ok -> :ok
        {:error, reason} -> {:error, "GitHub refused: #{inspect(reason)}"}
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "Couldn't reach GitHub: #{inspect(reason)}"}
    end
  end
end
