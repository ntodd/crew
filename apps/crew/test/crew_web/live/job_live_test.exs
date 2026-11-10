defmodule CrewWeb.JobLiveTest do
  @moduledoc "The job page (§17.6): steps, timing, placement, and the log viewer's server side."
  use CrewWeb.ConnCase

  import Ecto.Query

  alias Crew.{Jobs, Logs, Repo}
  alias Crew.VMs.VM

  @epoch "0123456789abcdef"

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "crew-joblogs-#{System.unique_integer([:positive])}")
    Application.put_env(:crew, :log_dir, dir)
    Application.put_env(:crew, :log_timers_ms, %{ack: 10, gap: 100})

    on_exit(fn ->
      Application.delete_env(:crew, :log_dir)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Crew.Logs.Supervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Crew.Logs.Supervisor, pid)

      File.rm_rf!(dir)
    end)

    admin = user_fixture(role: "admin")
    repo = repo_fixture(name: "web")
    box = box_fixture(name: "m4")
    run_id = 4242

    {:ok, _} =
      Jobs.handle_workflow_run(
        workflow_run_payload(repo, id: run_id, name: "CI", head_sha: "abc1234def")
      )

    steps = [
      %{
        "name" => "Set up job",
        "number" => 1,
        "status" => "completed",
        "conclusion" => "success",
        "started_at" => "2026-11-03T10:00:05Z",
        "completed_at" => "2026-11-03T10:00:06Z"
      },
      %{
        "name" => "Run tests",
        "number" => 2,
        "status" => "in_progress",
        "started_at" => "2026-11-03T10:00:06Z"
      }
    ]

    {:ok, job} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 77,
          run_id: run_id,
          name: "test",
          status: "in_progress",
          steps: steps
        )
      )

    vm = vm_for(job, box, repo)
    {:ok, _} = Jobs.link_vm(job.id, vm)

    %{
      conn: log_in(conn, admin),
      repo: repo,
      box: box,
      job: Jobs.get_job!(job.id),
      vm: vm,
      path: ~p"/runs/#{run_id}/attempts/1/jobs/77"
    }
  end

  defp vm_for(job, box, repo) do
    id = CrewProtocol.uuid7()
    size = Repo.get_by!(Crew.Sizes.Size, name: "m")
    now = DateTime.utc_now()

    Repo.insert!(%VM{
      id: id,
      box_id: box.id,
      name: CrewProtocol.Names.runner_name("abcd", box.name, id),
      repo_id: repo.id,
      class_key: ["crew-m"],
      class_hash: VM.class_hash(["crew-m"]),
      size_id: size.id,
      vcpus: 4,
      memory_mib: 8192,
      disk_gib: 60,
      state: "busy",
      job_id: job.id,
      deadline: DateTime.add(now, 3600),
      requested_at: DateTime.add(now, -60),
      idle_at: DateTime.add(now, -30),
      busy_at: DateTime.add(now, -20)
    })
  end

  defp write_live(vm, seq, lines) do
    lines =
      for {n, text, step} <- lines,
          do: %{n: n, t: 1_800_000_000_000 + n, step_ref: step, text: text}

    Crew.Logs.Stream.deliver(vm.id, {:log, %{epoch: @epoch, seq: seq, lines: lines}})
    last = lines |> List.last() |> Map.get(:n)
    wait_until(fn -> Logs.last_n(:vm, vm.id) == last end)
    # The index is saved with the stream's ack.
    wait_until(fn -> Enum.any?(Map.values(Logs.index(:vm, vm.id).steps), &(&1 <= last)) end)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "while it runs, its steps are the guest's, numbered as the run page's bar links to them",
       %{
         conn: conn,
         path: path,
         vm: vm
       } do
    steps =
      for {name, status, n} <- [
            {"Set up job", "completed", 1},
            {"Checkout", "completed", 2},
            {"Run tests", "in_progress", 3}
          ],
          do: %{"ref" => "s#{n}", "name" => name, "number" => n, "status" => status}

    :ok = Logs.handle_agent_event(vm, "vm.steps", %{steps: steps})

    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#step-2", "Checkout")
    assert has_element?(view, "#step-3", "Run tests")
  end

  test "shows the steps, the timing bar, placement and the viewer", %{
    conn: conn,
    path: path,
    vm: vm
  } do
    write_live(vm, 1, [
      {1, "::group::Install", "s1"},
      {2, "::endgroup::", "s1"},
      {3, "\e[31m::error::boom\e[0m", "s2"}
    ])

    {:ok, view, _} = live(conn, path)

    assert has_element?(view, "#steps", "Set up job")
    assert has_element?(view, "#steps", "Run tests")
    assert has_element?(view, "#timing")
    assert has_element?(view, "#placement", "m4")
    assert has_element?(view, "#placement", vm.name)

    viewer = view |> element("#log-viewer") |> render()
    assert viewer =~ ~s(phx-hook="LogViewer")
    assert viewer =~ ~s(phx-update="ignore")
    assert viewer =~ ~s(data-source="live")
    assert viewer =~ ~s(data-total="3")
    assert viewer =~ ~s(data-running="true")
    assert viewer =~ "abc1234def"
    # The index goes with the page: groups and annotations before the lines.
    assert viewer =~ "Install"
  end

  test "a spare job is tagged next to its size", %{conn: conn, path: path, job: job} do
    {:ok, view, _} = live(conn, path)
    refute has_element?(view, "#placement [data-tier]")

    Repo.update!(Ecto.Changeset.change(job, spare: true))
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#placement [data-tier]", "spare")
  end

  test "a waiting spare job: its size, the tag and why it waits", %{conn: conn, repo: repo} do
    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo, id: 78, run_id: 4242, name: "fuzz", labels: ["crew-l-spare"])
      )

    reason = "waiting for spare room: regular jobs are waiting for the boxes that fit"

    Repo.update_all(from(j in Crew.Jobs.Job, where: j.github_id == 78),
      set: [wait_reason: reason]
    )

    {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/78")
    assert has_element?(view, "#placement", "l")
    assert has_element?(view, "#placement [data-tier]", "spare")
    assert render(view) =~ reason
  end

  test "lines: a range from the file, clamped", %{conn: conn, path: path, vm: vm} do
    write_live(vm, 1, for(n <- 1..10, do: {n, "line #{n}", "s1"}))
    {:ok, view, _} = live(conn, path)

    render_hook(view, "lines", %{"source" => "live", "from" => 3, "to" => 5})
    assert_reply(view, %{lines: [%{n: 3, text: "line 3"}, %{n: 4}, %{n: 5}], total: 10})

    render_hook(view, "lines", %{"source" => "live", "from" => 1, "to" => 1_000_000})
    assert_reply(view, %{lines: lines})
    assert length(lines) == 10
  end

  test "search: hits, and errors", %{conn: conn, path: path, vm: vm} do
    write_live(vm, 1, [{1, "alpha", "s1"}, {2, "beta", "s1"}, {3, "Alpha", "s1"}])
    {:ok, view, _} = live(conn, path)

    render_hook(view, "search", %{
      "source" => "live",
      "q" => "alpha",
      "regex" => false,
      "case" => false
    })

    assert_reply(view, %{hits: [1, 3]})

    render_hook(view, "search", %{"source" => "live", "q" => "(", "regex" => true, "case" => true})

    assert_reply(view, %{error: "bad regex" <> _})
  end

  test "new lines are pushed to the viewer, coalesced", %{conn: conn, path: path, vm: vm} do
    {:ok, view, _} = live(conn, path)
    write_live(vm, 1, [{1, "first", "s1"}])
    write_live(vm, 2, [{2, "second", "s1"}])
    assert_push_event(view, "append", %{source: "live", lines: lines, total: total}, 1_000)
    assert Enum.map(lines, & &1.text) -- ["first", "second"] == []
    assert total in [1, 2]
  end

  test "the stream's saved index reaches the viewer", %{conn: conn, path: path, vm: vm} do
    {:ok, view, _} = live(conn, path)
    write_live(vm, 1, [{1, "::group::Setup", "s1"}, {2, "::endgroup::", "s1"}])
    assert_push_event(view, "index", %{index: %{groups: [[1, 2, "Setup"]]}}, 1_000)
  end

  test "GitHub's log replaces the live one when it arrives", %{conn: conn, path: path, job: job} do
    {:ok, view, _} = live(conn, path)
    Logs.store_github(job, "2026-11-03T10:00:05.000Z hello\n", false)
    {:ok, _} = Jobs.set_log_source(job, "github")
    assert_push_event(view, "source", %{source: "github", total: 1}, 1_000)
    assert has_element?(view, "#log-source", "GitHub")
  end

  test "both logs stay readable once GitHub's arrives: a toggle", %{
    conn: conn,
    path: path,
    job: job,
    vm: vm
  } do
    write_live(vm, 1, [{1, "from the VM", "s1"}])
    Logs.store_github(job, "2026-11-03T10:00:05.000Z from GitHub\n", false)
    {:ok, _} = Jobs.set_log_source(job, "github")
    {:ok, view, _} = live(conn, path)

    assert has_element?(view, "#log-source", "GitHub")
    assert has_element?(view, ~s(#download-raw[href$="source=github"]))
    view |> element("#show-live") |> render_click()
    assert_push_event(view, "source", %{source: "live", total: 1})
    assert has_element?(view, ~s(#download-raw[href$="source=live"]))
    view |> element("#show-github") |> render_click()
    assert_push_event(view, "source", %{source: "github", total: 1})
  end

  test "a VM linked after the page opened: the viewer starts over with its log", %{
    conn: conn,
    repo: repo,
    box: box
  } do
    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo, id: 78, run_id: 4242, name: "later", status: "queued")
      )

    {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/78")
    job = Jobs.get_job_by_github_id(78)
    vm = vm_for(job, box, repo)
    write_live(vm, 1, [{1, "setup", "s1"}])
    {:ok, _} = Jobs.link_vm(job.id, vm)
    assert_push_event(view, "source", %{source: "live", total: 1}, 1_000)
  end

  describe "cache misses (§16.7)" do
    defp deps_step(s, conclusion \\ "success") do
      %{
        "name" => "Run mix deps.get",
        "number" => 2,
        "status" => "completed",
        "conclusion" => conclusion,
        "started_at" => "2026-11-03T10:00:00Z",
        "completed_at" => DateTime.to_iso8601(DateTime.add(~U[2026-11-03 10:00:00Z], s))
      }
    end

    defp past_runs(job, durations) do
      for {s, i} <- Enum.with_index(durations, 1) do
        job_row_fixture(Crew.Repo.get!(Crew.Repos.Repo, job.repo_id),
          workflow_name: job.workflow_name,
          name: job.name,
          completed_at: DateTime.add(DateTime.utc_now(), -3600 * i),
          steps: [deps_step(s)]
        )
      end
    end

    defp with_deps_step(job, s) do
      steps = [
        hd(job.steps),
        deps_step(s),
        %{"name" => "Run tests", "number" => 3, "status" => "in_progress"}
      ]

      job |> Ecto.Changeset.change(steps: steps) |> Repo.update!()
    end

    test "a dependency step that took about as long on each recent run is flagged", %{
      conn: conn,
      path: path,
      job: job
    } do
      past_runs(job, [40, 42, 38, 45, 41])
      with_deps_step(job, 43)

      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#step-2 [data-cache-miss]", "No cache hit in 5 runs")
      refute has_element?(view, "#step-3 [data-cache-miss]")
    end

    test "not when this run's step was fast: the cache hit", %{conn: conn, path: path, job: job} do
      past_runs(job, [40, 42, 38, 45, 41])
      with_deps_step(job, 2)

      {:ok, view, _} = live(conn, path)
      refute has_element?(view, "[data-cache-miss]")
    end

    test "not when this run skipped it: the cache hit", %{conn: conn, path: path, job: job} do
      past_runs(job, [40, 42, 38, 45, 41])

      skipped = %{
        "name" => "Run mix deps.get",
        "number" => 2,
        "status" => "completed",
        "conclusion" => "skipped"
      }

      job
      |> Ecto.Changeset.change(steps: [hd(job.steps), skipped])
      |> Repo.update!()

      {:ok, view, _} = live(conn, path)
      refute has_element?(view, "[data-cache-miss]")
    end

    test "of two steps with one name, only the one that missed", %{
      conn: conn,
      path: path,
      job: job
    } do
      repo = Crew.Repo.get!(Crew.Repos.Repo, job.repo_id)
      twice = fn a, b -> [%{deps_step(a) | "number" => 2}, %{deps_step(b) | "number" => 3}] end

      for i <- 1..5 do
        job_row_fixture(repo,
          workflow_name: job.workflow_name,
          name: job.name,
          completed_at: DateTime.add(DateTime.utc_now(), -3600 * i),
          steps: twice.(40, 2)
        )
      end

      job |> Ecto.Changeset.change(steps: [hd(job.steps) | twice.(41, 2)]) |> Repo.update!()

      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#step-2 [data-cache-miss]")
      refute has_element?(view, "#step-3 [data-cache-miss]")
    end

    test "not when a recent run was fast", %{conn: conn, path: path, job: job} do
      past_runs(job, [40, 3, 38, 45, 41])
      with_deps_step(job, 43)

      {:ok, view, _} = live(conn, path)
      refute has_element?(view, "[data-cache-miss]")
    end
  end

  describe "right-sizing (§7.5)" do
    test "a finished job with enough runs shows its hint and the runs-on line", %{
      conn: conn,
      repo: repo
    } do
      summarized_jobs_fixture(repo, 4, name: "lint")
      summarized_job_fixture(repo, name: "lint", run_id: 4242, id: 88)

      {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/88")
      assert has_element?(view, "#sizing", "From the last 5 runs of this job")
      assert has_element?(view, "#sizing", "Try xs")
      assert has_element?(view, "#sizing", "frees 6.0 GiB a run")
      assert has_element?(view, "#sizing code", "runs-on: crew-xs")

      # The run's workflow file, where the line goes.
      assert has_element?(
               view,
               ~s(#sizing a[href="#{CrewWeb.GitHub.repo_url(repo)}/blob/main/.github/workflows/ci.yml"]),
               ".github/workflows/ci.yml"
             )

      # An issue for the change, on GitHub or copied.
      assert has_element?(
               view,
               ~s(#sizing a[href^="https://github.com/#{repo.full_name}/issues/new?"][target="_blank"]),
               "File issue"
             )

      assert has_element?(
               view,
               ~s(#sizing button[phx-hook="Copy"][data-copy^="# Move CI · lint to crew-xs"]),
               "Copy as Markdown"
             )
    end

    test "an admin dismisses the hint here; the page says so, with no issue, until it's restored",
         %{conn: conn, repo: repo} do
      summarized_jobs_fixture(repo, 4, name: "lint")
      summarized_job_fixture(repo, name: "lint", run_id: 4242, id: 94)

      {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/94")
      view |> element("#sizing button", "Dismiss") |> render_click()
      view |> form("#sizing-dismiss", %{"reason" => "lint stays on m"}) |> render_submit()

      assert has_element?(view, "#sizing", "Try xs")
      assert has_element?(view, "#sizing-dismissed", "Dismissed by")
      assert has_element?(view, "#sizing-dismissed", "lint stays on m")
      refute has_element?(view, "#sizing a", "File issue")
      refute has_element?(view, "#sizing button", "Dismiss")

      view |> element("#sizing-dismissed button", "Restore") |> render_click()
      refute has_element?(view, "#sizing-dismissed")
      assert has_element?(view, "#sizing a", "File issue")
    end

    test "a member sees it's dismissed, without the buttons", %{repo: repo} do
      summarized_jobs_fixture(repo, 4, name: "lint")
      job = summarized_job_fixture(repo, name: "lint", run_id: 4242, id: 95)
      admin = Crew.Scope.for_user(user_fixture(role: "admin"))
      %{kind: kind, from: from} = Crew.Sizing.for_job(job)

      {:ok, _} =
        Crew.Sizing.dismiss(admin, job.id, %{
          "kind" => to_string(kind),
          "vcpus" => to_string(from.vcpus),
          "memory_mib" => to_string(from.memory_mib)
        })

      member = user_fixture()

      Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/runs/4242/attempts/1/jobs/95")
      assert has_element?(view, "#sizing-dismissed", "Dismissed by #{admin.user.login}")
      refute has_element?(view, "#sizing button", "Restore")
      refute has_element?(view, "#sizing button", "Dismiss")
    end

    test "a member whose access lapsed is sent away, not shown the hint again", %{repo: repo} do
      summarized_jobs_fixture(repo, 4, name: "lint")
      summarized_job_fixture(repo, name: "lint", run_id: 4242, id: 96)
      member = user_fixture()

      Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/runs/4242/attempts/1/jobs/96")
      Repo.delete_all(Crew.Repos.Access)
      render_hook(view, "dismissing", %{"job" => "x"})
      assert_redirect(view, ~p"/runs")
    end

    test "a spare job keeps its tier, and its other labels stay", %{conn: conn, repo: repo} do
      spare = [name: "fuzz", labels: ["self-hosted", "crew-m-spare"]]
      summarized_jobs_fixture(repo, 4, spare)
      summarized_job_fixture(repo, [run_id: 4242, id: 93] ++ spare)

      {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/93")
      assert has_element?(view, "#sizing code", "runs-on: [self-hosted, crew-xs-spare]")

      assert has_element?(
               view,
               ~s(#sizing button[data-copy*="- runs-on: [self-hosted, crew-m-spare]"]),
               "Copy as Markdown"
             )
    end

    test "no file link for a run whose workflow isn't a file", %{conn: conn, repo: repo} do
      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 4343, path: "dynamic/dependabot/dependabot-updates")
        )

      summarized_jobs_fixture(repo, 4, name: "lint")
      summarized_job_fixture(repo, name: "lint", run_id: 4343, id: 92)

      {:ok, view, _} = live(conn, ~p"/runs/4343/attempts/1/jobs/92")
      assert has_element?(view, "#sizing code", "runs-on: crew-xs")
      refute has_element?(view, "#sizing a[href*='/blob/']")
    end

    test "a custom size tells an admin where to add it", %{conn: conn, repo: repo} do
      busy = [name: "build", cpu_excess: [1200.0, 600.0, 120.0]]
      summarized_jobs_fixture(repo, 4, busy)
      summarized_job_fixture(repo, [run_id: 4242, id: 89] ++ busy)

      {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/89")
      assert has_element?(view, "#sizing", "A custom size would fit")
      assert has_element?(view, "#sizing", "4 vCPU · 2.0 GiB · 20 GiB disk")
      assert has_element?(view, "#sizing a[href='/admin/sizes']", "Sizes & labels")
      refute has_element?(view, "#sizing code", "runs-on:")
      # Nothing to file until the size exists.
      refute has_element?(view, "#sizing a[href*='/issues/new']")
      refute has_element?(view, "#sizing [phx-hook='Copy']")

      # A member can't add sizes, so there's no link for them.
      member = user_fixture()

      Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/runs/4242/attempts/1/jobs/89")
      assert has_element?(view, "#sizing", "An admin can add it on Sizes & labels.")
      refute has_element?(view, "#sizing a[href='/admin/sizes']")
    end

    test "the job's median duration on each size it ran on", %{conn: conn, repo: repo} do
      l = [name: "lint", vcpus: 8, memory_mib: 16_384, cpu_excess: List.duplicate(0.0, 7)]
      summarized_jobs_fixture(repo, 3, l)
      summarized_jobs_fixture(repo, 2, name: "lint")
      summarized_job_fixture(repo, name: "lint", run_id: 4242, id: 90)

      {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/90")
      assert has_element?(view, "#sizing-durations li", "m (4 vCPU · 8.0 GiB)")
      assert has_element?(view, "#sizing-durations li", "l (8 vCPU · 16.0 GiB)")
      assert has_element?(view, "#sizing-durations li", "10m 00s")
      assert has_element?(view, "#sizing-durations li", "3 runs")
    end

    test "one size has nothing to compare", %{conn: conn, repo: repo} do
      summarized_jobs_fixture(repo, 4, name: "lint")
      summarized_job_fixture(repo, name: "lint", run_id: 4242, id: 91)

      {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1/jobs/91")
      refute has_element?(view, "#sizing-durations")
    end

    test "a job that's still running has none", %{conn: conn, path: path} do
      {:ok, view, _} = live(conn, path)
      refute has_element?(view, "#sizing")
    end
  end

  describe "access (§18.3)" do
    test "an open page whose access lapses stops getting lines, and goes", %{
      repo: repo,
      path: path,
      vm: vm
    } do
      member = user_fixture()

      Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      {:ok, view, _} = live(log_in(build_conn(), member), path)

      # Lapsed (6 hours without a refresh), with no notice sent.
      Repo.delete_all(Crew.Repos.Access)
      write_live(vm, 1, [{1, "secret", "s1"}])
      assert_redirect(view, ~p"/runs", 1_000)
    end

    test "a member who can't read the repo can't open it", %{repo: repo, path: path} do
      member = user_fixture()
      _ = repo
      assert_raise Ecto.NoResultsError, fn -> live(log_in(build_conn(), member), path) end
    end

    test "every event checks access again", %{repo: repo, path: path, vm: vm} do
      member = user_fixture()

      Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      write_live(vm, 1, [{1, "secret", "s1"}])
      {:ok, view, _} = live(log_in(build_conn(), member), path)

      Repo.delete_all(Crew.Repos.Access)
      render_hook(view, "lines", %{"source" => "live", "from" => 1, "to" => 1})
      assert_reply(view, %{error: "no access"})

      render_hook(view, "search", %{
        "source" => "live",
        "q" => "secret",
        "regex" => false,
        "case" => false
      })

      assert_reply(view, %{error: "no access"})
    end
  end

  describe "Download raw" do
    test "plain text, not sniffed, as an attachment", %{conn: conn, path: path, vm: vm} do
      write_live(vm, 1, [{1, "<script>alert(1)</script>", "s1"}, {2, "two", "s1"}])
      conn = get(conn, path <> "/log.txt?source=live")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert conn.resp_body == "<script>alert(1)</script>\ntwo\n"
    end

    test "a member without access gets a 404", %{path: path} do
      member = user_fixture()
      conn = get(log_in(build_conn(), member), path <> "/log.txt?source=live")
      assert conn.status == 404
    end
  end

  test "the run page links to the job", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/runs/4242/attempts/1")
    assert has_element?(view, ~s(a[href="/runs/4242/attempts/1/jobs/77"]))
  end
end
