defmodule CrewWeb.RunPageTest do
  @moduledoc """
  The run page (§17.3) as the page to watch a run on: links out to
  GitHub, the attempts, each job's progress through its steps, the box
  each ran on, and staying live.
  """
  use CrewWeb.ConnCase

  alias Crew.{Jobs, Logs, Repo}
  alias Crew.VMs.VM

  @run 5150

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "crew-runpage-#{System.unique_integer([:positive])}")
    Application.put_env(:crew, :log_dir, dir)
    on_exit(fn -> Application.delete_env(:crew, :log_dir) && File.rm_rf!(dir) end)

    repo = repo_fixture(name: "web")
    box = box_fixture(name: "m4")

    run = [
      id: @run,
      name: "CI",
      run_number: 1230,
      head_branch: "feat/live",
      head_sha: "f00dfacecafe1234",
      pull_requests: [%{"number" => 701}]
    ]

    {:ok, _} =
      Jobs.handle_workflow_run(
        workflow_run_payload(
          repo,
          run ++ [run_attempt: 1, status: "completed", conclusion: "failure"]
        )
      )

    {:ok, _} =
      Jobs.handle_workflow_run(
        workflow_run_payload(repo, run ++ [run_attempt: 2, status: "in_progress"])
      )

    {:ok, test} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 501,
          run_id: @run,
          run_attempt: 2,
          name: "test",
          status: "in_progress"
        )
      )

    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 502,
          run_id: @run,
          run_attempt: 2,
          name: "lint",
          labels: ["ubuntu-latest"],
          status: "completed",
          conclusion: "success",
          completed_at: "2026-11-03T10:01:00Z",
          steps: [
            %{
              "number" => 1,
              "name" => "Set up job",
              "status" => "completed",
              "conclusion" => "success"
            },
            %{"number" => 2, "name" => "Lint", "status" => "completed", "conclusion" => "success"}
          ]
        )
      )

    vm = vm_for(test, box, repo)
    {:ok, _} = Jobs.link_vm(test.id, vm)

    guest_steps(vm, [
      {"Set up job", "completed", "success"},
      {"Checkout", "completed", "success"},
      {"Run tests", "in_progress", nil},
      {"Lint", "pending", nil}
    ])

    %{
      conn: log_in(conn, user_fixture(role: "admin")),
      repo: repo,
      box: box,
      vm: vm,
      path: ~p"/runs/#{@run}/attempts/2"
    }
  end

  defp vm_for(job, box, repo) do
    id = CrewProtocol.uuid7()
    now = DateTime.utc_now()

    Repo.insert!(%VM{
      id: id,
      box_id: box.id,
      name: CrewProtocol.Names.runner_name("abcd", box.name, id),
      repo_id: repo.id,
      class_key: ["crew-m"],
      class_hash: VM.class_hash(["crew-m"]),
      size_id: Repo.get_by!(Crew.Sizes.Size, name: "m").id,
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

  defp guest_steps(vm, steps) do
    steps =
      for {{name, status, conclusion}, i} <- Enum.with_index(steps, 1) do
        %{
          "ref" => "s#{i}",
          "name" => name,
          "number" => i,
          "status" => status,
          "conclusion" => conclusion
        }
      end

    :ok = Logs.handle_agent_event(vm, "vm.steps", %{steps: steps})
  end

  test "the repo, branch, PR and commit link to GitHub in a new tab", %{conn: conn, path: path} do
    {:ok, view, _} = live(conn, path)

    for {href, text} <- [
          {"https://github.com/acme/web", "acme/web"},
          {"https://github.com/acme/web/tree/feat/live", "feat/live"},
          {"https://github.com/acme/web/pull/701", "PR #701"},
          {"https://github.com/acme/web/commit/f00dfacecafe1234", "f00dfac"}
        ] do
      assert has_element?(
               view,
               ~s(a[href="#{href}"][target="_blank"][rel~="noopener"]),
               text
             )
    end
  end

  test "the attempt menu lists every attempt, and marks this one", %{conn: conn, path: path} do
    {:ok, view, _} = live(conn, path)

    assert has_element?(view, "#attempts summary", "Attempt 2")
    assert has_element?(view, ~s(#attempts a[href="/runs/#{@run}/attempts/1"]), "Attempt 1")

    assert has_element?(
             view,
             ~s(#attempts a[href="/runs/#{@run}/attempts/2"][aria-current="page"])
           )

    assert has_element?(view, ~s(#attempts a[href$="/attempts/1"] [class~="hero-x-circle-micro"]))
  end

  test "the run's status icon is solid", %{conn: conn, path: path} do
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, ~s(#run-status [class~="hero-play-circle-micro"]))
  end

  test "each job shows its progress through its steps", %{conn: conn, path: path} do
    {:ok, view, _} = live(conn, path)

    assert has_element?(view, "#job-501 [data-steps]", "2/4")
    assert has_element?(view, "#job-501 [data-steps]", "Run tests")

    assert view |> element("#job-501 [data-steps]") |> render() |> step_states() ==
             ~w(success success running pending)

    assert has_element?(view, "#job-502 [data-steps]", "2/2")
  end

  test "running times carry their start, for the page's clock to count up", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#run-page[phx-hook=Clock]")
    assert has_element?(view, "#job-501 [data-job-state=running] [data-from]")
    assert has_element?(view, ~s(#job-501 td[data-col="run"] [data-from]))
    assert has_element?(view, "#run-duration[data-from]")
    refute has_element?(view, "#job-502 [data-from]")
  end

  test "a done attempt's duration stops, even with a job still to report", %{
    conn: conn,
    path: path,
    repo: repo
  } do
    {:ok, _} =
      Jobs.handle_workflow_run(
        workflow_run_payload(repo,
          id: @run,
          run_attempt: 2,
          status: "completed",
          conclusion: "success",
          action: "completed"
        )
      )

    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#job-501 [data-from]")
    refute has_element?(view, "#run-duration[data-from]")
  end

  test "the box card keeps up with the box", %{conn: conn, path: path, box: box} do
    {:ok, view, _} = live(conn, path)
    refute has_element?(view, "#box-card-#{box.id}", "Draining")
    Repo.update!(Ecto.Changeset.change(box, draining: true))
    send(view.pid, :refresh)
    assert has_element?(view, "#box-card-#{box.id}", "Draining")
  end

  test "the box link is described for screen readers by a summary of its card", %{
    conn: conn,
    path: path,
    box: box
  } do
    {:ok, view, _} = live(conn, path)

    assert has_element?(
             view,
             ~s(#job-501 a[data-card="box-card-#{box.id}"][aria-describedby="box-summary-#{box.id}"])
           )

    assert has_element?(view, "#box-summary-#{box.id}", "m4")
    assert has_element?(view, "#box-summary-#{box.id}", "1 VM")
  end

  test "the steps keep up while the run is live", %{conn: conn, path: path, vm: vm} do
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#job-501 [data-steps]", "2/4")

    guest_steps(vm, [
      {"Set up job", "completed", "success"},
      {"Checkout", "completed", "success"},
      {"Run tests", "completed", "success"},
      {"Lint", "in_progress", nil}
    ])

    send(view.pid, :refresh)
    assert has_element?(view, "#job-501 [data-steps]", "3/4")
    assert has_element?(view, "#job-501 [data-steps]", "Lint")
  end

  test "the box links to its page, with a card of what it's running", %{
    conn: conn,
    path: path,
    box: box
  } do
    {:ok, view, _} = live(conn, path)

    assert has_element?(
             view,
             ~s(#job-501 a[href="/boxes/#{box.id}"][data-card="box-card-#{box.id}"]),
             "m4"
           )

    assert has_element?(view, ~s(#box-card-#{box.id}[popover]), "m4")
    assert has_element?(view, "#box-card-#{box.id}", "1 VM ·")
    assert has_element?(view, "#box-card-#{box.id}", "Memory (GiB)")
  end

  test "an earlier attempt's page names it in the menu", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/runs/#{@run}/attempts/1")
    assert has_element?(view, "#attempts summary", "Attempt 1")
    assert has_element?(view, ~s(#attempts a[href$="/attempts/2"]), "Attempt 2")
  end

  defp step_states(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-step-state]")
    |> LazyHTML.attribute("data-step-state")
  end
end
