defmodule Crew.Fixtures do
  @moduledoc "Builds records for tests."

  alias Crew.Repo

  def unique, do: System.unique_integer([:positive])

  def user_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    n = unique()

    %Crew.Accounts.User{
      login: Map.get(attrs, :login, "user#{n}"),
      github_id: Map.get(attrs, :github_id, n),
      name: Map.get(attrs, :name, "User #{n}"),
      role: Map.get(attrs, :role, "member"),
      access_token: Map.get(attrs, :access_token, "ghu_user#{n}"),
      access_token_expires_at:
        Map.get(attrs, :access_token_expires_at, DateTime.add(DateTime.utc_now(), 8 * 3600)),
      refresh_token: Map.get(attrs, :refresh_token, "ghr_user#{n}"),
      refresh_token_expires_at: DateTime.add(DateTime.utc_now(), 86_400 * 180),
      disabled_at: Map.get(attrs, :disabled_at)
    }
    |> Repo.insert!()
  end

  def installation_fixture(attrs \\ []) do
    attrs = Map.new(attrs)

    %Crew.Repos.Installation{
      github_id: Map.get(attrs, :github_id, unique()),
      account_login: Map.get(attrs, :account_login, "acme"),
      account_type: "Organization",
      permissions:
        Map.get(attrs, :permissions, %{
          "administration" => "write",
          "actions" => "write",
          "metadata" => "read",
          "pull_requests" => "read",
          "members" => "read"
        })
    }
    |> Repo.insert!()
  end

  def repo_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    installation = Map.get_lazy(attrs, :installation, fn -> installation_fixture() end)
    name = Map.get(attrs, :name, "repo#{unique()}")

    %Crew.Repos.Repo{
      installation_id: installation.id,
      github_id: Map.get(attrs, :github_id, unique()),
      full_name: "#{installation.account_login}/#{name}",
      private: Map.get(attrs, :private, true),
      enabled: Map.get(attrs, :enabled, true),
      fork_prs: Map.get(attrs, :fork_prs, "refuse"),
      allowed_sizes: Map.get(attrs, :allowed_sizes),
      priority: Map.get(attrs, :priority, 0),
      max_concurrent: Map.get(attrs, :max_concurrent)
    }
    |> Repo.insert!()
    |> Repo.preload(:installation)
  end

  @doc "A workflow schedule (§7.6). Its clock starts an hour ago unless `last_due_at` says otherwise."
  def schedule_fixture(repo, attrs \\ []) do
    attrs = Map.new(attrs)

    %Crew.Schedules.Schedule{
      repo_id: repo.id,
      workflow: Map.get(attrs, :workflow, "flake-hunt.yml"),
      ref: Map.get(attrs, :ref, "main"),
      cron: Map.get(attrs, :cron, "17 7 * * *"),
      enabled: Map.get(attrs, :enabled, true),
      last_due_at: Map.get(attrs, :last_due_at, DateTime.add(DateTime.utc_now(), -3600)),
      last_dispatched_at: Map.get(attrs, :last_dispatched_at),
      last_error: Map.get(attrs, :last_error)
    }
    |> Repo.insert!()
  end

  @doc "A workflow_job webhook payload (GitHub's shape, trimmed to what Crew reads)."
  def workflow_job_payload(repo, attrs \\ []) do
    attrs = Map.new(attrs)
    id = Map.get(attrs, :id, unique())
    run_id = Map.get(attrs, :run_id, unique())
    status = Map.get(attrs, :status, "queued")

    %{
      "action" => Map.get(attrs, :action, status),
      "workflow_job" => %{
        "id" => id,
        "run_id" => run_id,
        "run_attempt" => Map.get(attrs, :run_attempt, 1),
        "name" => Map.get(attrs, :name, "test"),
        "workflow_name" => Map.get(attrs, :workflow_name, "CI"),
        "labels" => Map.get(attrs, :labels, ["crew-m"]),
        "status" => status,
        "conclusion" => Map.get(attrs, :conclusion),
        "created_at" => Map.get(attrs, :created_at, "2026-11-03T10:00:00Z"),
        "started_at" => Map.get(attrs, :started_at, "2026-11-03T10:00:05Z"),
        "completed_at" => Map.get(attrs, :completed_at),
        "runner_name" => Map.get(attrs, :runner_name),
        "runner_id" => Map.get(attrs, :runner_id),
        "head_branch" => "main",
        "head_sha" => "abc123",
        "steps" => Map.get(attrs, :steps, [])
      },
      "repository" => %{
        "id" => repo.github_id,
        "full_name" => repo.full_name,
        "private" => repo.private
      },
      "installation" => %{"id" => repo.installation.github_id}
    }
  end

  @doc "A workflow_run webhook payload."
  def workflow_run_payload(repo, attrs \\ []) do
    attrs = Map.new(attrs)
    head_repo = Map.get(attrs, :head_repo, repo.full_name)

    %{
      "action" => Map.get(attrs, :action, "requested"),
      "workflow_run" => %{
        "id" => Map.get(attrs, :id, unique()),
        "run_attempt" => Map.get(attrs, :run_attempt, 1),
        "run_number" => Map.get(attrs, :run_number, 12),
        "name" => Map.get(attrs, :name, "CI"),
        "event" => Map.get(attrs, :event, "push"),
        "status" => Map.get(attrs, :status, "queued"),
        "conclusion" => Map.get(attrs, :conclusion),
        "head_branch" => Map.get(attrs, :head_branch, "main"),
        "head_sha" => Map.get(attrs, :head_sha, "abc1234def"),
        "head_commit" => %{"message" => Map.get(attrs, :message, "Fix the thing")},
        "actor" => %{"login" => Map.get(attrs, :actor, "mona"), "id" => 1},
        "pull_requests" => Map.get(attrs, :pull_requests, []),
        "head_repository" => if(head_repo, do: %{"full_name" => head_repo}),
        "created_at" => "2026-11-03T10:00:00Z",
        "updated_at" => "2026-11-03T10:00:01Z"
      },
      "repository" => %{
        "id" => repo.github_id,
        "full_name" => repo.full_name,
        "private" => repo.private
      },
      "installation" => %{"id" => repo.installation.github_id}
    }
  end

  @doc "A box with an enrolled key; `private_key/1` has the agent's, for signing connects."
  def box_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    {public, private} = CrewProtocol.Auth.generate_keypair()
    caps = Map.get(attrs, :capabilities, capabilities())

    box =
      %Crew.Boxes.Box{
        name: Map.get(attrs, :name, "box#{unique()}"),
        type: Map.get(attrs, :type, "mac-vz"),
        driver: caps["driver"],
        guest_arch: caps["guest_arch"],
        public_key: public,
        key_fingerprint: CrewProtocol.Auth.fingerprint(public),
        agent_version: "0.1.0",
        protocol_version: CrewProtocol.version(),
        capabilities: caps,
        pinned_capabilities: Map.get(attrs, :pinned_capabilities, caps),
        firewall_ok: Map.get(attrs, :firewall_ok, true),
        draining: Map.get(attrs, :draining, false),
        needs_approval: Map.get(attrs, :needs_approval, false),
        quarantined_until: Map.get(attrs, :quarantined_until),
        max_vms: Map.get(attrs, :max_vms),
        revoked_at: Map.get(attrs, :revoked_at)
      }
      |> Repo.insert!()

    :persistent_term.put({__MODULE__, :private_key, box.id}, private)
    box
  end

  @doc """
  A VM row on `box`, with no server behind it: what it holds of the box,
  its state and its times. A busy size-m VM by default.
  """
  def vm_fixture(box, attrs \\ []) do
    repo = Repo.one(Ecto.Query.first(Crew.Repos.Repo)) || repo_fixture()

    Repo.insert!(
      struct!(
        %Crew.VMs.VM{
          id: CrewProtocol.uuid7(),
          box_id: box.id,
          repo_id: repo.id,
          size_id: Repo.get_by!(Crew.Sizes.Size, name: "m").id,
          name: "vm-#{unique()}",
          class_key: ["crew-m"],
          class_hash: Crew.VMs.VM.class_hash(["crew-m"]),
          vcpus: 4,
          memory_mib: 8192,
          disk_gib: 60,
          vmm_overhead_mib: 128,
          state: "busy",
          deadline: DateTime.add(DateTime.utc_now(), 3600),
          requested_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  @doc "A `box.metrics` sample for `box` at `t` (Unix seconds)."
  def box_metric_fixture(box, t, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Crew.Metrics.BoxMetric{
          box_id: box.id,
          t: t,
          cpu_pct: 10.0,
          mem_used_mib: 4096,
          mem_total_mib: 131_072,
          swap_used_mib: 0,
          load1: 1.0,
          disk_used_mib: 100_000,
          disk_total_mib: 1_000_000,
          vm_area_free_mib: 300_000,
          cache_used_mib: 0,
          vms_running: 0
        },
        attrs
      )
    )
  end

  @doc """
  A finished Crew job with a final resource summary (§16.5): a successful
  10-minute run on m that needed little, unless `attrs` say otherwise.
  `started_at` sets when it ran; `name`, `workflow_name`, `conclusion`
  and `run_id` go to its webhook, the rest to its summary.
  """
  def summarized_job_fixture(repo, attrs \\ []) do
    attrs = Map.new(attrs)
    # Recent, since repo pages look at the last 30 days.
    started = Map.get_lazy(attrs, :started_at, fn -> ago(86_400) end)
    hook = [:name, :workflow_name, :conclusion, :run_id, :id, :labels]

    {:ok, job} =
      Crew.Jobs.handle_workflow_job(
        workflow_job_payload(
          repo,
          Keyword.merge(
            [
              id: unique(),
              status: "completed",
              conclusion: "success",
              started_at: DateTime.to_iso8601(started),
              completed_at: DateTime.to_iso8601(DateTime.add(started, 600))
            ],
            attrs |> Map.take(hook) |> Map.to_list()
          )
        )
      )

    summary =
      Map.merge(
        %{
          vcpus: 4,
          memory_mib: 8192,
          peak_mem_mib: 1000,
          peak_disk_mib: 3000,
          cpu_excess: [0.0, 0.0, 0.0],
          cpu_pressure_pct: 0.0,
          mem_pressure_pct: 0.0,
          mem_full_pressure_pct: 0.0,
          oom: false,
          coverage: 1.0
        },
        Map.drop(attrs, [:started_at | hook])
      )

    import Ecto.Query, only: [from: 2]
    Repo.update_all(from(j in Crew.Jobs.Job, where: j.id == ^job.id), set: Map.to_list(summary))

    Repo.get!(Crew.Jobs.Job, job.id)
  end

  @doc "`n` of `summarized_job_fixture/2`, an hour apart, the newest last, all before its default."
  def summarized_jobs_fixture(repo, n, attrs \\ []) do
    for i <- 1..n,
        do:
          summarized_job_fixture(
            repo,
            Keyword.merge([started_at: ago(2 * 86_400 - i * 3600)], attrs)
          )
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)

  @doc """
  A job row written as is, with no webhook behind it: a finished,
  successful Crew job on m unless `attrs` say otherwise.
  """
  def job_row_fixture(repo, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Crew.Jobs.Job{
          repo_id: repo.id,
          github_id: unique(),
          github_run_id: unique(),
          classification: "ours",
          gh_state: "completed",
          conclusion: "success",
          runner_name: "crew-runner",
          seen_at: DateTime.utc_now(),
          workflow_name: "CI",
          name: "test",
          size_id: Repo.get_by!(Crew.Sizes.Size, name: "m").id
        },
        attrs
      )
    )
  end

  @doc """
  A VM on `box` for `repo` that ran a job `busy` seconds long on `day`
  (UTC), from 01:00: 30 s of boot, 30 s idle, the job, 10 s of
  teardown. Returns the VM.
  """
  def ran_fixture(box, repo, day, busy, attrs \\ []) do
    at = fn s ->
      day
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(s)
      |> Map.put(:microsecond, {0, 6})
    end

    vm =
      vm_fixture(
        box,
        Keyword.merge(
          [
            repo_id: repo.id,
            requested_at: at.(3600),
            idle_at: at.(3630),
            busy_at: at.(3660),
            finished_at: at.(3660 + busy),
            destroyed_at: at.(3670 + busy),
            state: "destroyed"
          ],
          attrs
        )
      )

    job_row_fixture(repo,
      vm_id: vm.id,
      started_at: at.(3660),
      completed_at: at.(3660 + busy)
    )

    vm
  end

  @doc "A `vm.metrics` sample for `vm` at `t` (Unix seconds)."
  def vm_metric_fixture(vm, t, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Crew.Metrics.VMMetric{
          vm_id: vm.id,
          box_id: vm.box_id,
          job_id: vm.job_id,
          t: t,
          cpu_pct: 10.0,
          mem_used_mib: 1024,
          mem_total_mib: vm.memory_mib,
          disk_used_mib: 2048
        },
        attrs
      )
    )
  end

  @doc "The private key `box_fixture/1` enrolled for the box, for signing its agent's connects."
  def private_key(box_id), do: :persistent_term.get({__MODULE__, :private_key, box_id})

  def capabilities(overrides \\ %{}) do
    Map.merge(
      %{
        "driver" => "vz",
        "driver_version" => "0.1.0",
        "guest_arch" => "arm64",
        "vcpus" => 18,
        "memory_mib" => 110_592,
        "vm_area_mib" => 409_600,
        "max_vcpus_per_vm" => 18,
        "max_memory_mib_per_vm" => 110_592,
        "vmm_overhead_mib" => 128,
        "features" => [],
        "virtualized" => false,
        "hypervisor_vendor" => nil,
        "firewall_ok" => true
      },
      Map.new(overrides, fn {k, v} -> {to_string(k), v} end)
    )
  end
end
