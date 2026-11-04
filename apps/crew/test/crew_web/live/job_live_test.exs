defmodule CrewWeb.JobLiveTest do
  @moduledoc "The job page (§17.6): steps, timing, placement, and the log viewer's server side."
  use CrewWeb.ConnCase

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

  test "lines: a range from the file, clamped", %{conn: conn, path: path, vm: vm} do
    write_live(vm, 1, for(n <- 1..10, do: {n, "line #{n}", "s1"}))
    {:ok, view, _} = live(conn, path)

    render_hook(view, "lines", %{"source" => "live", "from" => 3, "to" => 5})
    assert_reply(view, %{lines: [%{n: 3, text: "line 3"}, %{n: 4}, %{n: 5}]})

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

  describe "access (§18.3)" do
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
