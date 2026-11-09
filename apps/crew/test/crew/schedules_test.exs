defmodule Crew.SchedulesTest do
  use Crew.DataCase
  use Oban.Testing, repo: Crew.Repo

  alias Crew.{Schedules, Scope}
  alias Crew.GitHubStub
  alias Crew.Schedules.{Schedule, Tick}

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Application.put_env(:crew, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: pem
    })

    on_exit(fn -> Application.delete_env(:crew, :github_app) end)
    Crew.GitHub.InstallationTokens.clear()
    Crew.GitHub.Budget.reset()

    %{
      repo: repo_fixture(name: "app"),
      admin: Scope.for_user(user_fixture(role: "admin")),
      member: Scope.for_user(user_fixture(role: "member"))
    }
  end

  # Stubs the token exchange and the dispatch for `workflow` in `repo`.
  defp stub(repo, dispatch, workflow \\ "flake-hunt.yml") do
    GitHubStub.stub(%{
      {"POST", "/app/installations/#{repo.installation.github_id}/access_tokens"} =>
        {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}},
      {"POST", "/repos/#{repo.full_name}/actions/workflows/#{workflow}/dispatches"} => dispatch
    })
  end

  defp accept(test_pid) do
    fn conn ->
      send(test_pid, {:dispatched, conn.request_path, GitHubStub.body(conn)})
      Plug.Conn.send_resp(conn, 204, "")
    end
  end

  defp audited(action),
    do: Repo.exists?(from e in Crew.Audit.Event, where: e.action == ^action)

  describe "changeset" do
    test "needs a workflow file, a ref and a cron", %{repo: repo} do
      blank = Schedules.change(%Schedule{repo_id: repo.id}, %{workflow: "", ref: "", cron: ""})

      assert %{workflow: ["can't be blank"], ref: ["can't be blank"], cron: ["can't be blank"]} =
               errors_on(blank)

      bad =
        Schedules.change(%Schedule{repo_id: repo.id}, %{
          workflow: "flake hunt",
          ref: "my branch",
          cron: "17 7 * *"
        })

      assert %{workflow: [_], ref: [_], cron: [cron]} = errors_on(bad)
      assert cron =~ "five fields"

      good =
        Schedules.change(%Schedule{repo_id: repo.id}, %{
          workflow: "flake-hunt.yml",
          ref: "main",
          cron: "17 7 * * *"
        })

      assert good.valid?
    end

    test "@reboot and the other Oban-only forms aren't schedules", %{repo: repo} do
      for cron <- ["@reboot", "17 7 * * * *"] do
        cs =
          Schedules.change(%Schedule{repo_id: repo.id}, %{
            workflow: "ci.yml",
            ref: "main",
            cron: cron
          })

        refute cs.valid?, cron
      end
    end
  end

  describe "create, update and delete" do
    test "admins manage a repo's schedules, audited; members don't", ctx do
      attrs = %{"workflow" => "flake-hunt.yml", "ref" => "main", "cron" => "17 7 * * *"}
      Schedules.subscribe(ctx.repo.id)

      assert {:error, :unauthorized} = Schedules.create(ctx.member, ctx.repo, attrs)
      assert {:ok, %Schedule{} = s} = Schedules.create(ctx.admin, ctx.repo, attrs)
      assert_receive {:schedules_changed, repo_id}
      assert repo_id == ctx.repo.id

      assert s.enabled
      # The clock starts now: the first fire is the next 07:17, not a 07:17 that has passed.
      assert DateTime.diff(DateTime.utc_now(), s.last_due_at) in 0..5
      assert Enum.map(Schedules.list(ctx.repo.id), & &1.id) == [s.id]

      assert {:error, :unauthorized} = Schedules.update(ctx.member, s, %{"enabled" => false})
      assert {:ok, s} = Schedules.update(ctx.admin, s, %{"enabled" => false})
      refute s.enabled

      assert {:error, :unauthorized} = Schedules.delete(ctx.member, s)
      assert {:ok, _} = Schedules.delete(ctx.admin, s)
      assert Schedules.list(ctx.repo.id) == []

      for action <- ~w(schedule.create schedule.update schedule.delete),
          do: assert(audited(action), action)
    end

    test "enabling a schedule, or changing its cron, restarts its clock", ctx do
      past = ~U[2026-11-10 06:00:00.000000Z]
      s = schedule_fixture(ctx.repo, enabled: false, last_due_at: past)

      # A week off, then on again: the matches it missed aren't owed.
      assert {:ok, s} = Schedules.update(ctx.admin, s, %{"enabled" => true})
      assert DateTime.diff(DateTime.utc_now(), s.last_due_at) in 0..5

      # Other edits leave the clock alone.
      s = Repo.update!(Ecto.Changeset.change(s, last_due_at: past))
      assert {:ok, s} = Schedules.update(ctx.admin, s, %{"ref" => "release"})
      assert s.last_due_at == past

      # A new cron starts fresh too: its past matches aren't owed either.
      assert {:ok, s} = Schedules.update(ctx.admin, s, %{"cron" => "0 3 * * *"})
      assert DateTime.diff(DateTime.utc_now(), s.last_due_at) in 0..5
    end

    test "the same workflow, ref and cron can't be scheduled twice", ctx do
      attrs = %{"workflow" => "flake-hunt.yml", "ref" => "main", "cron" => "17 7 * * *"}
      assert {:ok, _} = Schedules.create(ctx.admin, ctx.repo, attrs)
      assert {:error, %Ecto.Changeset{} = cs} = Schedules.create(ctx.admin, ctx.repo, attrs)
      assert %{cron: [message]} = errors_on(cs)
      assert message =~ "already scheduled"
    end

    test "a bad cron comes back as a changeset", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Schedules.create(ctx.admin, ctx.repo, %{
                 "workflow" => "ci.yml",
                 "ref" => "main",
                 "cron" => "nope"
               })
    end
  end

  describe "due/1" do
    test "a schedule is due once its minute arrives; a tick missed within the hour still fires",
         %{
           repo: repo
         } do
      s = schedule_fixture(repo, cron: "17 7 * * *", last_due_at: ~U[2026-11-10 06:00:00.000000Z])

      assert Schedules.due(~U[2026-11-10 07:16:59.000000Z]) == []
      assert [%Schedule{id: id}] = Schedules.due(~U[2026-11-10 07:17:00.000000Z])
      assert id == s.id
      # The control plane was down at 07:17 and back at 07:40: it fires, late.
      assert [_] = Schedules.due(~U[2026-11-10 07:40:00.000000Z])
      # Back at 09:00: a 2 AM job isn't worth starting now. It waits for tomorrow.
      assert Schedules.due(~U[2026-11-10 09:00:00.000000Z]) == []
      assert [_] = Schedules.due(~U[2026-11-11 07:17:00.000000Z])
    end

    test "skips disabled schedules, and disabled or archived repos", %{repo: repo} do
      schedule_fixture(repo, enabled: false, last_due_at: ~U[2026-11-10 06:00:00.000000Z])

      off = repo_fixture(name: "off", enabled: false)
      schedule_fixture(off, last_due_at: ~U[2026-11-10 06:00:00.000000Z])

      gone = repo_fixture(name: "gone")
      Repo.update!(Ecto.Changeset.change(gone, archived_at: DateTime.utc_now()))
      schedule_fixture(gone, last_due_at: ~U[2026-11-10 06:00:00.000000Z])

      assert Schedules.due(~U[2026-11-10 07:17:00.000000Z]) == []
    end
  end

  describe "fire/2" do
    test "posts a workflow_dispatch for the ref and records it", %{repo: repo} do
      stub(repo, accept(self()))

      s =
        schedule_fixture(repo,
          workflow: "flake-hunt.yml",
          ref: "main",
          cron: "17 7 * * *",
          last_due_at: ~U[2026-11-10 06:00:00.000000Z],
          last_error: "HTTP 500: boom"
        )

      assert {:ok, %Schedule{} = s} = Schedules.fire(s, ~U[2026-11-10 07:17:05.000000Z])
      assert_received {:dispatched, path, %{"ref" => "main"}}
      assert path == "/repos/#{repo.full_name}/actions/workflows/flake-hunt.yml/dispatches"

      assert s.last_dispatched_at == ~U[2026-11-10 07:17:05.000000Z]
      assert s.last_due_at == ~U[2026-11-10 07:17:00.000000Z]
      assert s.last_error == nil

      # Accounted for: not due again until tomorrow.
      assert Schedules.due(~U[2026-11-10 07:18:00.000000Z]) == []
      assert Schedules.due(~U[2026-11-10 23:59:00.000000Z]) == []
      assert [_] = Schedules.due(~U[2026-11-11 07:17:00.000000Z])
    end

    test "keeps GitHub's answer when the dispatch fails, and still moves the clock", %{repo: repo} do
      stub(repo, {422, %{"message" => "Workflow does not have 'workflow_dispatch' trigger"}})

      s =
        schedule_fixture(repo,
          last_due_at: ~U[2026-11-10 06:00:00.000000Z],
          last_dispatched_at: ~U[2026-11-09 07:17:05.000000Z]
        )

      assert {:error, %Schedule{} = s} = Schedules.fire(s, ~U[2026-11-10 07:17:05.000000Z])
      assert s.last_error == "HTTP 422: Workflow does not have 'workflow_dispatch' trigger"
      assert s.last_dispatched_at == ~U[2026-11-09 07:17:05.000000Z]
      assert s.last_due_at == ~U[2026-11-10 07:17:00.000000Z]
      # A broken schedule fails once a day, not once a minute.
      assert Schedules.due(~U[2026-11-10 07:18:00.000000Z]) == []
    end
  end

  describe "fire/2 against itself" do
    test "claims the minute before dispatching, so an overlapping tick dispatches nothing", %{
      repo: repo
    } do
      stub(repo, accept(self()))
      s = schedule_fixture(repo, last_due_at: ~U[2026-11-10 06:00:00.000000Z])

      assert {:ok, _} = Schedules.fire(s, ~U[2026-11-10 07:17:05.000000Z])
      assert_received {:dispatched, _, _}

      # The same stale row, as a tick that loaded it before the first one saved.
      assert :already_fired = Schedules.fire(s, ~U[2026-11-10 07:17:40.000000Z])
      refute_received {:dispatched, _, _}
    end

    test "a dispatch that crashes is recorded like a refusal", %{repo: repo} do
      stub(repo, fn _conn -> raise "connection reset" end)
      s = schedule_fixture(repo, last_due_at: ~U[2026-11-10 06:00:00.000000Z])

      assert {:error, %Schedule{} = s} = Schedules.fire(s, ~U[2026-11-10 07:17:05.000000Z])
      assert s.last_error =~ "connection reset"
      assert s.last_due_at == ~U[2026-11-10 07:17:00.000000Z]
    end
  end

  describe "run_now/2" do
    test "an admin dispatches at once; the schedule's own clock doesn't move", ctx do
      stub(ctx.repo, accept(self()))
      s = schedule_fixture(ctx.repo, last_due_at: ~U[2026-11-10 06:00:00.000000Z])

      assert {:error, :unauthorized} = Schedules.run_now(ctx.member, s)
      refute_received {:dispatched, _, _}

      assert {:ok, %Schedule{} = s} = Schedules.run_now(ctx.admin, s)
      assert_received {:dispatched, _, %{"ref" => "main"}}
      assert s.last_dispatched_at
      assert s.last_due_at == ~U[2026-11-10 06:00:00.000000Z]
      assert audited("schedule.run")
    end
  end

  describe "the tick" do
    test "fires what's due and nothing else", %{repo: repo} do
      stub(repo, accept(self()))

      due =
        schedule_fixture(repo,
          cron: "* * * * *",
          last_due_at: DateTime.add(DateTime.utc_now(), -120)
        )

      not_yet =
        schedule_fixture(repo,
          workflow: "later.yml",
          cron: "* * * * *",
          last_due_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      assert :ok = perform_job(Tick, %{})

      assert_received {:dispatched, path, _}
      assert path =~ "/flake-hunt.yml/"
      refute_received {:dispatched, _, _}

      assert Repo.reload!(due).last_dispatched_at
      refute Repo.reload!(not_yet).last_dispatched_at
    end

    test "a schedule that crashes doesn't stop the others", %{repo: repo} do
      test = self()

      GitHubStub.stub(%{
        {"POST", "/app/installations/#{repo.installation.github_id}/access_tokens"} =>
          {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}},
        {"POST", "/repos/#{repo.full_name}/actions/workflows/boom.yml/dispatches"} => fn _conn ->
          raise "boom"
        end,
        {"POST", "/repos/#{repo.full_name}/actions/workflows/flake-hunt.yml/dispatches"} =>
          accept(test)
      })

      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120)

      boom =
        schedule_fixture(repo,
          workflow: "boom.yml",
          cron: "* * * * *",
          last_due_at: two_minutes_ago
        )

      ok = schedule_fixture(repo, cron: "* * * * *", last_due_at: two_minutes_ago)

      assert :ok = perform_job(Tick, %{})

      assert_received {:dispatched, path, _}
      assert path =~ "/flake-hunt.yml/"
      assert Repo.reload!(ok).last_dispatched_at
      assert Repo.reload!(boom).last_error =~ "boom"
    end

    test "a second tick in the same minute isn't queued" do
      assert %Oban.Job{conflict?: false} = Oban.insert!(Tick.new(%{}))
      assert %Oban.Job{conflict?: true} = Oban.insert!(Tick.new(%{}))
    end

    test "does nothing until the App exists", %{repo: repo} do
      Application.delete_env(:crew, :github_app)

      schedule_fixture(repo,
        cron: "* * * * *",
        last_due_at: DateTime.add(DateTime.utc_now(), -120)
      )

      assert :ok = perform_job(Tick, %{})
      assert [%{last_dispatched_at: nil}] = Schedules.list(repo.id)
    end
  end

  test "next_at/2 is the next minute the cron matches, after now", %{repo: repo} do
    s = schedule_fixture(repo, cron: "17 7 * * *")
    assert Schedules.next_at(s, ~U[2026-11-10 09:00:00.000000Z]) == ~U[2026-11-11 07:17:00Z]
    assert Schedules.next_at(s, ~U[2026-11-10 07:17:00.000000Z]) == ~U[2026-11-11 07:17:00Z]
    assert Schedules.next_at(s, ~U[2026-11-10 07:16:59.000000Z]) == ~U[2026-11-10 07:17:00Z]
  end
end
