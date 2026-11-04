defmodule Crew.Agents.Updates do
  @moduledoc """
  Agent updates (§20.2), Foreman's `Agents.Releases.maybe_update/1` and
  its settling, for Crew.

  **What a box should run** (`target_version/1`): the version an admin
  pinned it to, or else the newest registered for its target (its
  join's os and arch), with crew_cache's tarball too on Linux.

  **When it's sent:** on join, when a newer release registers, when an
  admin pins or retries, and from the sweep every minute; only to a box
  that's online, isn't on it already, has no update under way, and
  hasn't failed it twice. `agent.update` carries the control plane's own
  URLs for the tarballs, their SHA-256s, sizes and signatures.

  **How it settles** (the operation's status):
  - `dispatched`: sent. The agent answers once it has swapped releases
    (`restart: true`), which makes it `running` with
    `restart_reported_at` in its args, or with an error.
  - `succeeded`: the box joined on the version (whatever it reported).
  - `failed`: the agent refused it or reported a rollback
    (`rolled_back`, from the release it came back on); the box came
    back on the version it left at least 30 s after the restart was
    reported (sooner is the old release reconnecting before it exits);
    or it's overdue, 20 minutes after it was sent (the agent waits up
    to 10 for operations in flight) or 10 after the restart (5 to join,
    and the rollbacks).

  **Two failures** of a version in a row on a box (Foreman's rule) stop
  it being sent there: the box's `failed_agent_version`, until an admin
  retries it or pins another. One might be bad luck.
  """
  import Ecto.Query

  require Logger

  alias Crew.Agents.Releases
  alias Crew.Boxes.Box
  alias Crew.Operations.Operation
  alias Crew.{Agents, Operations, Repo}

  @dispatched_grace 20 * 60
  @restart_grace 10 * 60
  @rejoin_grace 30

  @doc "The release target of a box's agent, from its join; nil before one."
  def target(%Box{os: os, arch: arch}), do: Releases.target(os, arch)

  @doc "The version a box should run: its pin, or the newest for its target."
  def target_version(%Box{desired_agent_version: pinned}) when is_binary(pinned), do: pinned

  def target_version(%Box{} = box) do
    case target(box) do
      nil -> nil
      target -> Releases.fleet_version(target)
    end
  end

  @doc "After a join (`Crew.Agents.joined/3`): settles the box's updates, then sends one if due."
  def joined(%Box{} = box, _join) do
    settle(box, joined: true)
    maybe_update(box)
  end

  @doc "A release registered: the boxes online behind it get it."
  def released do
    for id <- Agents.online_ids(), box = Repo.get(Box, id), do: maybe_update(box)
    :ok
  end

  @doc """
  Every minute (`Crew.Agents.UpdateSweep`): settles the updates under
  way, overdue ones included, and sends what's due to the boxes online.
  """
  def sweep do
    boxes =
      Repo.all(
        from b in Box,
          join: o in Operation,
          on: o.box_id == b.id,
          where: o.command == "agent.update" and o.status in ["dispatched", "running"],
          distinct: true,
          select: b
      )

    Enum.each(boxes, &settle/1)
    released()
  end

  # -- sending --------------------------------------------------------------------

  @doc """
  Sends `agent.update` to a box that's due one. One at a time per box:
  a join and the sweep can arrive together.
  """
  def maybe_update(%Box{id: id}) do
    :global.trans({{__MODULE__, id}, self()}, fn ->
      with %Box{} = box <- Repo.get(Box, id), do: send_update(box)
    end)

    :ok
  end

  defp send_update(box) do
    with nil <- box.revoked_at,
         true <- Agents.online?(box.id),
         target when is_binary(target) <- target(box),
         version when is_binary(version) <- target_version(box),
         true <- version != box.agent_version,
         true <- version != box.failed_agent_version,
         [] <- active(box),
         %{agent: agent, cache: cache} <- Releases.update_set(target, version) do
      payload =
        Map.merge(file(agent), %{version: version})
        |> then(&if(cache, do: Map.put(&1, :cache, file(cache)), else: &1))

      Logger.info("sending agent #{version} to box #{box.name} (on #{box.agent_version})")
      result = Operations.dispatch(box.id, "agent.update", payload, record: %{"target" => target})
      Crew.Boxes.broadcast_changed(box.id)
      result
    end
  end

  defp file(release) do
    %{
      url: Releases.update_url(release),
      sha256: release.sha256,
      size: release.size,
      signature: release.signature
    }
  end

  # -- settling -------------------------------------------------------------------

  @doc """
  Settles the box's updates under way against the version it runs. With
  `joined: true` (a join), a box back on the version it left counts as a
  rollback. Returns the box as it is after.
  """
  def settle(%Box{} = box, opts \\ []) do
    now = DateTime.utc_now()

    for op <- active(box) do
      version = op.args["version"]
      from = (op.result || %{})["from"]

      cond do
        version == box.agent_version ->
          op
          |> Operations.settle("succeeded", result: Map.put(op.result || %{}, "version", version))
          |> succeeded()

        opts[:joined] && op.status == "running" && from == box.agent_version &&
            since(op, "restart_reported_at", now) >= @rejoin_grace ->
          op
          |> Operations.settle("failed",
            error_code: "rolled_back",
            error: "the box came back on #{from} after restarting into #{version}"
          )
          |> failed()

        overdue?(op, now) ->
          op
          |> Operations.settle("failed",
            error_code: "timeout",
            error:
              "the agent didn't come back on #{version}; it's on #{box.agent_version || "nothing yet"}"
          )
          |> failed()

        true ->
          :ok
      end
    end

    Crew.Boxes.broadcast_changed(box.id)
    Repo.reload(box)
  end

  defp overdue?(%Operation{status: "running"} = op, now),
    do: since(op, "restart_reported_at", now) > @restart_grace

  defp overdue?(%Operation{} = op, now),
    do: DateTime.diff(now, op.dispatched_at || op.inserted_at) > @dispatched_grace

  defp since(op, key, now) do
    case DateTime.from_iso8601((op.args || %{})[key] || "") do
      {:ok, at, _} -> DateTime.diff(now, at)
      _ -> DateTime.diff(now, op.dispatched_at || op.inserted_at)
    end
  end

  @doc """
  An `agent.update`'s result was recorded (`Crew.Operations`): a failure
  counts toward the two, and what's due goes out again.
  """
  def result_recorded(%Operation{command: "agent.update", status: "failed"} = op) do
    failed(op)
    maybe_update(%Box{id: op.box_id})
  end

  def result_recorded(%Operation{command: "agent.update", status: "succeeded"} = op),
    do: succeeded(op)

  def result_recorded(_op), do: :ok

  defp succeeded(%Operation{box_id: box_id, args: %{"version" => version}}) do
    from(b in Box,
      where:
        b.id == ^box_id and not is_nil(b.failed_agent_version) and
          b.failed_agent_version != ^version
    )
    |> Repo.update_all(set: [failed_agent_version: nil])

    :ok
  end

  defp succeeded(_op), do: :ok

  # Twice in a row and the version isn't sent again.
  defp failed(%Operation{box_id: box_id, args: %{"version" => version}}) do
    if failed_twice?(box_id, version) do
      Logger.warning("agent #{version} failed twice on box #{box_id}; not sending it again")

      from(b in Box, where: b.id == ^box_id)
      |> Repo.update_all(set: [failed_agent_version: version])

      Crew.Boxes.broadcast_changed(box_id)
    end

    :ok
  end

  defp failed(_op), do: :ok

  # The box's last two finished updates, leaving out those that never
  # reached it (it went offline) and those an admin has retried.
  defp failed_twice?(box_id, version) do
    from(o in Operation,
      where:
        o.box_id == ^box_id and o.command == "agent.update" and
          o.status in ["succeeded", "failed"] and
          (is_nil(o.error_code) or o.error_code != "offline"),
      order_by: [desc: o.inserted_at],
      limit: 2,
      select: {o.status, o.args}
    )
    |> Repo.all()
    |> case do
      [{"failed", %{"version" => ^version} = a}, {"failed", %{"version" => ^version} = b}] ->
        not Map.has_key?(a, "retried") and not Map.has_key?(b, "retried")

      _ ->
        false
    end
  end

  @doc "Sets the box's failed updates aside, so a retried version gets its two tries again."
  def forget_failures(%Box{id: box_id}) do
    from(o in Operation,
      where: o.box_id == ^box_id and o.command == "agent.update" and o.status == "failed"
    )
    |> Repo.all()
    |> Enum.each(fn op ->
      op
      |> Ecto.Changeset.change(args: Map.put(op.args || %{}, "retried", true))
      |> Repo.update!()
    end)
  end

  defp active(box) do
    Repo.all(
      from o in Operation,
        where:
          o.box_id == ^box.id and o.command == "agent.update" and
            o.status in ["dispatched", "running"],
        order_by: o.inserted_at
    )
  end

  # -- for the box page -----------------------------------------------------------

  @doc """
  Where a box stands, for its page: the version it should run (and
  whether that's a pin), and `state`:

  - `:current`, on it;
  - `:pending`, behind, and it's sent when the box is next online;
  - `:updating`, sent; `:restarting`, installed and restarting into it;
  - `:blocked`, it failed twice here;
  - `:missing`, the version's files aren't on this control plane (a pin
    to a version whose copies are gone), so it can't be sent;
  - `:none`, nothing to run (no release for the box's target).

  `last` is the box's latest update, and `error` its failure if it failed.
  """
  def status(%Box{} = box) do
    version = target_version(box)

    last =
      Repo.one(
        from o in Operation,
          where: o.box_id == ^box.id and o.command == "agent.update",
          order_by: [desc: o.inserted_at],
          limit: 1
      )

    %{
      version: version,
      pinned: is_binary(box.desired_agent_version),
      target: target(box),
      state: state(box, version, last),
      last: last,
      error: if(last && last.status == "failed", do: last.error)
    }
  end

  defp state(_box, nil, _last), do: :none
  defp state(_box, _version, %Operation{status: "dispatched"}), do: :updating
  defp state(_box, _version, %Operation{status: "running"}), do: :restarting
  defp state(%Box{agent_version: version}, version, _last), do: :current

  defp state(box, version, _last) do
    cond do
      version not in Releases.versions(target(box)) -> :missing
      version == box.failed_agent_version -> :blocked
      true -> :pending
    end
  end
end
