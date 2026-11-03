defmodule Crew.GitHub.HookWorker do
  @moduledoc """
  Processes a webhook delivery (§6.4), off the request path.

  | Event | What Crew does |
  |---|---|
  | `workflow_job` | Upsert the job (§8.2) |
  | `workflow_run` | Upsert the run attempt |
  | `installation`, `installation_repositories` | Sync installations and repos |
  | `ping` | Record it for the Deployment page's webhook check |

  Everything else is acknowledged and dropped. Oban uniqueness is on
  `(event, object id, action)`, where the object is the job or the run
  attempt (`Webhook.object_id/3`), so the same news under a second
  delivery id is processed once.
  """
  use Oban.Worker,
    queue: :hooks,
    max_attempts: 10,
    unique: [period: 3600, keys: [:event, :object_id, :action]]

  import Ecto.Query

  alias Crew.{Jobs, Repo, Repos, Settings}
  alias Crew.GitHub.{Delivery, Webhook}

  @doc """
  Records a delivery and queues its processing, in one transaction.
  `:duplicate` if the delivery id was seen before.
  """
  def record(delivery_id, event, action, payload) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      {count, _} =
        Repo.insert_all(
          Delivery,
          [%{github_delivery_id: delivery_id, event: event, action: action, received_at: now}],
          on_conflict: :nothing,
          conflict_target: [:github_delivery_id]
        )

      if count == 1 do
        {:ok, _} =
          %{
            event: event,
            action: action,
            delivery_id: delivery_id,
            object_id: Webhook.object_id(event, payload, delivery_id),
            payload: payload
          }
          |> new()
          |> Oban.insert()

        {:ok, :new}
      else
        {:ok, :duplicate}
      end
    end)
    |> elem(1)
  end

  @impl true
  def perform(%Oban.Job{args: %{"event" => event, "payload" => payload} = args}) do
    result = dispatch(event, payload["action"], payload)
    mark(args["delivery_id"], result)

    case result do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp dispatch("workflow_job", _action, payload), do: ok(Jobs.handle_workflow_job(payload))
  defp dispatch("workflow_run", _action, payload), do: ok(Jobs.handle_workflow_run(payload))

  defp dispatch("installation", action, %{"installation" => installation})
       when action in ["created", "new_permissions_accepted", "unsuspend"] do
    with {:ok, i} <- Repos.upsert_installation(installation) do
      Repos.sync_installation(i)
      if action == "new_permissions_accepted", do: Jobs.reclassify_open()
      :ok
    end
  end

  defp dispatch("installation", "suspend", %{"installation" => %{"id" => id}}),
    do: ok(Repos.set_suspended(id, true))

  defp dispatch("installation", "deleted", %{"installation" => %{"id" => id}}),
    do: Repos.installation_removed(id)

  defp dispatch("installation_repositories", _action, %{"installation" => %{"id" => id}} = p) do
    Repos.repos_added(id, p["repositories_added"] || [])
    Repos.repos_removed(id, p["repositories_removed"] || [])
  end

  defp dispatch("ping", _action, payload) do
    Settings.put("webhook_ping", %{
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "hook_id" => payload["hook_id"],
      "zen" => payload["zen"]
    })

    :ok
  end

  defp dispatch(_event, _action, _payload), do: :ok

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other

  defp mark(nil, _result), do: :ok

  defp mark(delivery_id, result) do
    {processed_at, error} =
      case result do
        {:error, reason} -> {nil, inspect(reason) |> String.slice(0, 1000)}
        _ -> {DateTime.utc_now(), nil}
      end

    Repo.update_all(from(d in Delivery, where: d.github_delivery_id == ^delivery_id),
      set: [processed_at: processed_at, error: error]
    )

    :ok
  end
end
