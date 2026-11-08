# For tests/18-sizing.spec.js only (E2E_SEED=seeds/sizing.exs): a repo
# whose jobs have finished runs with final resource summaries (§16.5), so
# its page and its jobs' pages have right-sizing hints (§7.5) to show:
#
#   - CI · test needs little: try xs;
#   - CI · build needs 4 vCPUs but 1 GiB: a custom size;
#   - CI · e2e had a process killed for memory: larger;
#   - Nightly · integration waits on its CPUs: faster;
#   - CI · lint fits m, so the repo page doesn't list it.
import Ecto.Query

alias Crew.Jobs
alias Crew.Jobs.Job
alias Crew.Repo

installation =
  Repo.insert!(%Crew.Repos.Installation{
    github_id: 990_001,
    account_login: "mona",
    account_type: "Organization",
    permissions: %{
      "administration" => "write",
      "actions" => "write",
      "metadata" => "read",
      "pull_requests" => "read",
      "members" => "read"
    }
  })

repo =
  Repo.insert!(%Crew.Repos.Repo{
    installation_id: installation.id,
    github_id: 990_101,
    full_name: "mona/storefront",
    private: true,
    enabled: true,
    fork_prs: "refuse",
    priority: 0
  })
  |> Repo.preload(:installation)

hook = fn kind, body ->
  Map.merge(body, %{
    "repository" => %{"id" => repo.github_id, "full_name" => repo.full_name, "private" => true},
    "installation" => %{"id" => installation.github_id},
    "action" => kind
  })
end

now = DateTime.utc_now() |> DateTime.truncate(:second)
next = :counters.new(1, [])

on_m = %{
  peak_cpu_pct: 46.0,
  avg_cpu_pct: 21.0,
  vcpus: 4,
  memory_mib: 8192,
  peak_mem_mib: 1100,
  peak_disk_mib: 6000,
  cpu_excess: [0.0, 0.0, 0.0],
  cpu_pressure_pct: 0.5,
  mem_pressure_pct: 0.0,
  mem_full_pressure_pct: 0.0,
  oom: false,
  coverage: 1.0
}

# One finished run of `workflow` · `name`, `hours` ago, with its summary.
finish = fn workflow, name, hours, summary, conclusion ->
  :counters.add(next, 1, 1)
  n = :counters.get(next, 1)
  run_id = 7_700_000 + n
  started = DateTime.add(now, -hours * 3600)
  completed = DateTime.add(started, Map.get(summary, :duration, 540))

  {:ok, _} =
    Jobs.handle_workflow_run(
      hook.("completed", %{
        "workflow_run" => %{
          "id" => run_id,
          "run_attempt" => 1,
          "run_number" => 100 + n,
          "name" => workflow,
          "event" => "push",
          "status" => "completed",
          "conclusion" => conclusion,
          "head_branch" => "main",
          "head_sha" => "5e5d1c0ffee#{n}",
          "head_commit" => %{"message" => "Ship the cart page"},
          "actor" => %{"login" => "mona", "id" => 1},
          "pull_requests" => [],
          "head_repository" => %{"full_name" => repo.full_name},
          "created_at" => DateTime.to_iso8601(started),
          "updated_at" => DateTime.to_iso8601(completed)
        }
      })
    )

  {:ok, job} =
    Jobs.handle_workflow_job(
      hook.("completed", %{
        "workflow_job" => %{
          "id" => 8_800_000 + n,
          "run_id" => run_id,
          "run_attempt" => 1,
          "name" => name,
          "workflow_name" => workflow,
          "labels" => [Map.get(summary, :label, "crew-m")],
          "status" => "completed",
          "conclusion" => conclusion,
          "created_at" => DateTime.to_iso8601(DateTime.add(started, -20)),
          "started_at" => DateTime.to_iso8601(started),
          "completed_at" => DateTime.to_iso8601(completed),
          "runner_name" => nil,
          "head_branch" => "main",
          "head_sha" => "5e5d1c0ffee#{n}",
          "steps" => []
        }
      })
    )

  Repo.update_all(from(j in Job, where: j.id == ^job.id),
    set: summary |> Map.drop([:duration, :label]) |> Map.to_list()
  )
end

for h <- 1..8, do: finish.("CI", "test", 2 * h, %{on_m | peak_mem_mib: 1000 + h * 20}, "success")

for h <- 1..6,
    do:
      finish.(
        "CI",
        "build",
        2 * h + 1,
        %{on_m | peak_mem_mib: 900, cpu_excess: [1500.0, 700.0, 90.0], cpu_pressure_pct: 4.0},
        "success"
      )

on_l = %{
  on_m
  | vcpus: 8,
    memory_mib: 16_384,
    peak_mem_mib: 9000,
    cpu_excess: List.duplicate(0.0, 7)
}

for h <- 2..6, do: finish.("CI", "e2e", 3 * h, Map.put(on_l, :label, "crew-l"), "success")

finish.(
  "CI",
  "e2e",
  1,
  Map.merge(on_l, %{label: "crew-l", peak_mem_mib: 16_100, oom: true}),
  "failure"
)

on_s = %{on_m | vcpus: 2, memory_mib: 4096, peak_mem_mib: 1500, cpu_excess: [400.0]}

for h <- 1..6,
    do:
      finish.(
        "Nightly",
        "integration",
        24 * h,
        Map.merge(on_s, %{label: "crew-s", cpu_pressure_pct: 38.0 + h, duration: 1800}),
        "success"
      )

for h <- 1..6, do: finish.("CI", "lint", 2 * h, %{on_m | peak_mem_mib: 5200}, "success")
