defmodule Crew.Audit do
  @moduledoc "An append-only record of who changed what. Never stores secret values."
  import Ecto.Query

  alias Crew.Audit.Event
  alias Crew.Repo

  def log(scope_or_user, action, subject \\ nil, metadata \\ %{}) do
    actor =
      case scope_or_user do
        %Crew.Scope{user: user} -> user
        %Crew.Accounts.User{} = user -> user
        _ -> nil
      end

    {subject_type, subject_id} = subject_ref(subject)

    %Event{
      actor_id: actor && actor.id,
      actor_login: actor && actor.login,
      action: action,
      subject_type: subject_type,
      subject_id: subject_id,
      metadata: metadata
    }
    |> Repo.insert!()
  end

  defp subject_ref(nil), do: {nil, nil}

  defp subject_ref(%{__struct__: mod, id: id}),
    do: {mod |> Module.split() |> List.last(), to_string(id)}

  defp subject_ref({type, id}), do: {type, to_string(id)}

  def recent(limit \\ 200) do
    Event |> order_by(desc: :inserted_at) |> limit(^limit) |> Repo.all()
  end
end
