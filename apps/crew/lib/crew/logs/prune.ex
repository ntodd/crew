defmodule Crew.Logs.Prune do
  @moduledoc """
  Log retention (§9.4), hourly: logs older than `CREW_LOG_RETENTION_DAYS`
  go, and then, while everything stored is over `CREW_LOG_MAX_GIB`, the
  oldest. A VM that isn't destroyed keeps its log, whatever its age.
  A log's age is its last write.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 1800]

  import Ecto.Query

  alias Crew.{Logs, Repo}
  alias Crew.VMs.VM

  @impl true
  def perform(_job) do
    days = Application.get_env(:crew, :log_retention_days, 30)

    cap =
      Application.get_env(:crew, :log_max_bytes) ||
        Application.get_env(:crew, :log_max_gib, 20) * 1024 ** 3

    cutoff = System.os_time(:second) - days * 86_400

    {active, logs} = Enum.split_with(all_logs(), & &1.active)
    {old, kept} = Enum.split_with(logs, &(&1.mtime < cutoff))
    Enum.each(old, &delete/1)

    # Over the cap: the oldest first. Active logs count, but stay.
    _total =
      kept
      |> Enum.sort_by(& &1.mtime)
      |> Enum.reduce(Enum.sum_by(kept ++ active, & &1.bytes), fn log, total ->
        if total > cap do
          delete(log)
          total - log.bytes
        else
          total
        end
      end)

    :ok
  end

  defp all_logs do
    live = MapSet.new(Repo.all(from v in VM, where: v.state != "destroyed", select: v.id))

    for kind <- [:vm, :job],
        dir <- Path.wildcard(Path.join([Logs.dir(), to_string(kind), "*"])),
        id = Path.basename(dir),
        CrewProtocol.uuid?(id) do
      %{
        kind: kind,
        id: id,
        dir: dir,
        bytes: dir_bytes(dir),
        mtime: dir_mtime(dir),
        active: kind == :vm and MapSet.member?(live, id)
      }
    end
  end

  defp dir_bytes(dir) do
    dir |> Path.join("*") |> Path.wildcard() |> Enum.sum_by(&size/1)
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  defp dir_mtime(dir) do
    [dir | Path.wildcard(Path.join(dir, "*"))]
    |> Enum.map(fn p ->
      case File.stat(p, time: :posix) do
        {:ok, %{mtime: t}} -> t
        _ -> 0
      end
    end)
    |> Enum.max()
  end

  defp delete(log) do
    File.rm_rf!(log.dir)

    Repo.delete_all(
      from s in "log_segments",
        where: s.source == ^to_string(log.kind) and s.owner_id == ^Ecto.UUID.dump!(log.id)
    )
  end
end
