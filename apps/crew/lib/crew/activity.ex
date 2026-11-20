defmodule Crew.Activity do
  @moduledoc """
  The activity feed (§17.3, Foreman's `Activity`): boxes joining and
  leaving, quarantines, stalls, approvals, image rollouts, CA rotations,
  OS updates flagged, reboots and rollbacks.

  Each event is stored for the dashboard's feed and broadcast on
  `activity`, where every LiveView (through `CrewWeb.UserAuth`) shows it
  as a notice. An event about a repo carries its id, so members who can't
  read the repo see it masked (§18.3).
  """
  import Ecto.Query

  alias Crew.Activity.Event
  alias Crew.{Repo, Scope}

  @topic "activity"

  @kinds ~w(box_joined box_online box_offline box_revoked box_quarantined box_needs_approval
            box_approved box_reboot_required box_rebooted box_rolled_back class_stalled
            image_rollout ca_rotated fork_refused vm_killed notice)

  @doc "Subscribes the caller to new events."
  def subscribe, do: Phoenix.PubSub.subscribe(Crew.PubSub, @topic)

  @masked "Something happened in a repo you can't see."

  @doc """
  Records an event and broadcasts it. An event about a repo takes
  `masked:`, its text without the repo, workflow, job or branch names,
  which is what members who can't read the repo see (§18.3).
  """
  def record(kind, message, attrs \\ %{}) when kind in @kinds and is_binary(message) do
    attrs = Map.new(attrs)
    metadata = Map.get(attrs, :metadata, %{})

    metadata =
      if attrs[:repo_id],
        do: Map.put(metadata, "masked", attrs[:masked] || @masked),
        else: metadata

    event =
      Repo.insert!(%Event{
        kind: kind,
        message: message,
        box_id: attrs[:box_id],
        repo_id: attrs[:repo_id],
        metadata: metadata
      })

    Phoenix.PubSub.broadcast(Crew.PubSub, @topic, {:activity, event})
    event
  end

  @doc "The newest events `scope` may see, newest first, masked where it must be."
  def recent(%Scope{} = scope, limit \\ 50) do
    # UUIDv7s order by millisecond only, so the microsecond timestamp
    # comes first.
    Event
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&for_scope(&1, scope))
  end

  @doc """
  The event as `scope` may see it: as recorded for admins, for events
  about no repo and for repos the member can read; masked otherwise.
  """
  def for_scope(%Event{repo_id: nil} = event, _scope), do: event

  def for_scope(%Event{} = event, scope) do
    if Scope.admin?(scope) or can_read?(scope, event.repo_id),
      do: event,
      else: %{event | message: event.metadata["masked"] || @masked}
  end

  defp can_read?(scope, repo_id), do: Crew.Repos.can_read?(scope, repo_id)
end
