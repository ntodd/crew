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
        "actor" => %{"login" => "mona", "id" => 1},
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
end
