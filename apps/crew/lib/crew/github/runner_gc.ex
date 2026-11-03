defmodule Crew.GitHub.RunnerGC do
  @moduledoc """
  Runner garbage collection (§6.3), every 10 minutes. For each repo with
  Crew activity in the past 24 hours, its runners are listed, and every
  runner named `crew-<this deployment id>-*` is deleted when it has no VM
  row, or a VM row in `failed` or `destroyed`, online or not.

  It catches what a runner delete gave up on (a GitHub outage past the
  retry window) and JIT runners whose VM never came up. Runners of other
  deployments, and anyone else's, are never touched. A runner with a job
  answers 422 and is left: JIT runners go once their job is done.
  """
  use Oban.Worker, queue: :github, max_attempts: 1, unique: [period: 300]

  import Ecto.Query

  require Logger

  alias Crew.{Repo, Settings}
  alias Crew.GitHub.Client
  alias Crew.Repos.Repo, as: GitRepo
  alias Crew.VMs.VM

  @window_s 86_400
  @collect ~w(failed destroyed)

  @impl true
  def perform(_job) do
    case Settings.deployment_id() do
      nil -> :ok
      deployment -> Enum.each(active_repos(), &collect(&1, deployment))
    end

    :ok
  end

  defp active_repos do
    since = DateTime.add(DateTime.utc_now(), -@window_s)
    with_vms = from(v in VM, where: v.requested_at > ^since, distinct: true, select: v.repo_id)

    Repo.all(
      from r in GitRepo,
        where: r.last_activity_at > ^since or r.id in subquery(with_vms),
        preload: :installation
    )
  end

  defp collect(repo, deployment) do
    case Client.list_runners(repo.installation.github_id, repo.full_name) do
      {:ok, runners} ->
        ours = Enum.filter(runners, &CrewProtocol.Names.ours?(&1["name"], deployment))
        states = vm_states(Enum.map(ours, & &1["name"]))

        for runner <- ours, garbage?(Map.get(states, runner["name"])) do
          delete(repo, runner)
        end

      error ->
        Logger.warning("runner GC: listing #{repo.full_name}'s runners: #{inspect(error)}")
    end
  end

  defp garbage?(nil), do: true
  defp garbage?(state), do: state in @collect

  defp vm_states([]), do: %{}

  defp vm_states(names),
    do: Map.new(Repo.all(from v in VM, where: v.name in ^names, select: {v.name, v.state}))

  defp delete(repo, runner) do
    case Client.delete_runner(repo.installation.github_id, repo.full_name, runner["id"]) do
      {:ok, _} -> :ok
      error -> Logger.warning("runner GC: deleting #{runner["name"]}: #{inspect(error)}")
    end
  end
end
