defmodule Crew.Operations do
  @moduledoc """
  Commands sent to agents (§10.3) and their results. Each command's
  `op_id` is its operation's id. What's stored is the command with its
  secrets removed (`CrewProtocol.Command.redact/1`): the JIT config is
  never written to a table (§6.3).
  """
  import Ecto.Query

  alias Crew.{Agents, Repo}
  alias Crew.Operations.Operation
  alias CrewProtocol.Command

  def get!(id), do: Repo.get!(Operation, id)
  def get(id), do: Repo.get(Operation, id)

  def subscribe(op_id), do: Phoenix.PubSub.subscribe(Crew.PubSub, "op:#{op_id}")

  @doc """
  Validates a command, records it and sends it to the box's agent. A box
  that isn't connected gets nothing (`{:error, :offline}`), and no row.
  """
  def dispatch(box_id, type, payload, opts \\ []) do
    op_id = CrewProtocol.uuid7()

    with {:ok, cmd} <- Command.new(type, payload, op_id: op_id),
         true <- Agents.online?(box_id) || {:error, :offline} do
      now = DateTime.utc_now()

      op =
        Repo.insert!(%Operation{
          id: op_id,
          box_id: box_id,
          vm_id: opts[:vm_id] || Map.get(cmd.payload, :vm_id),
          user_id: opts[:user_id],
          command: type,
          args: cmd |> Command.to_wire() |> Map.fetch!("payload") |> Command.redact(),
          status: "dispatched",
          dispatched_at: now
        })

      case Agents.send_command(box_id, cmd) do
        :ok -> {:ok, op}
        {:error, :offline} -> {:ok, fail(op, "offline", "the box went offline")}
      end
    end
  end

  @doc "Records an `op.result` from `box_id`'s agent; refuses another box's operation."
  def record_result(box_id, %{op_id: op_id} = payload) do
    case Repo.get(Operation, op_id) do
      %Operation{box_id: ^box_id, status: status} = op when status in ["queued", "dispatched"] ->
        op = finish(op, payload)
        Phoenix.PubSub.broadcast(Crew.PubSub, "op:#{op.id}", {:op_result, op})
        :ok

      # A result resent after a reconnect is acknowledged and ignored.
      %Operation{box_id: ^box_id} ->
        :ok

      %Operation{} ->
        {:error, "not this box's operation"}

      nil ->
        {:error, "unknown operation"}
    end
  end

  defp finish(op, %{status: "ok"} = payload) do
    op
    |> Ecto.Changeset.change(
      status: "succeeded",
      result: payload[:result] || %{},
      finished_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp finish(op, payload) do
    error = payload[:error] || %{}
    fail(op, error[:code] || "error", error[:message])
  end

  defp fail(op, code, message) do
    op
    |> Ecto.Changeset.change(
      status: "failed",
      error_code: code,
      error: message,
      finished_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  def recent_for_box(box_id, limit \\ 20) do
    Repo.all(
      from o in Operation,
        where: o.box_id == ^box_id,
        order_by: [desc: o.inserted_at],
        limit: ^limit
    )
  end
end
