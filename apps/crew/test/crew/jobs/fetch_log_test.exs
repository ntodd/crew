defmodule Crew.Jobs.FetchLogTest do
  @moduledoc "GitHub's log, the authoritative one (§16.3)."
  use Crew.VMCase

  alias Crew.Jobs.FetchLog
  alias Crew.Logs

  @steps [
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
      "status" => "completed",
      "conclusion" => "success",
      "started_at" => "2026-11-03T10:00:06Z",
      "completed_at" => "2026-11-03T10:00:20Z"
    }
  ]

  @log "﻿2026-11-03T10:00:05.1000000Z Current runner version: '2.330.0'\r\n" <>
         "2026-11-03T10:00:05.2000000Z ##[group]Operating System\n" <>
         "2026-11-03T10:00:05.3000000Z ##[endgroup]\n" <>
         "2026-11-03T10:00:06.5000000Z \e[32mok\e[0m 12 tests\n" <>
         "a line without a timestamp\n" <>
         "2026-11-03T10:00:19.9000000Z done\n"

  setup %{repo: repo} do
    dir = Path.join(System.tmp_dir!(), "crew-logs-#{System.unique_integer([:positive])}")
    Application.put_env(:crew, :log_dir, dir)
    on_exit(fn -> Application.delete_env(:crew, :log_dir) && File.rm_rf!(dir) end)

    job = queued_job(repo, id: 801)

    {:ok, job} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 801,
          run_id: job.github_run_id,
          status: "completed",
          conclusion: "success",
          steps: @steps
        )
      )

    %{job: job}
  end

  defp routes(repo, logs) do
    Map.merge(github_routes(repo), %{
      {"GET", "/repos/#{repo.full_name}/actions/jobs/801/logs"} => logs
    })
  end

  test "completing a job schedules the fetch 5 s later", %{job: job} do
    assert [%{scheduled_at: at, args: %{"job_id" => id, "attempt" => 0}}] =
             all_enqueued(worker: FetchLog)

    assert id == job.id
    assert DateTime.diff(at, DateTime.utc_now()) in 3..5
  end

  test "it follows the redirect without sending the installation's token, and splits the log by step",
       %{job: job, repo: repo} do
    test = self()

    GitHubStub.stub(
      Map.merge(
        routes(repo, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://blob.example/logs/801?sig=x")
          |> Plug.Conn.send_resp(302, "")
        end),
        %{
          {"GET", "/logs/801"} => fn conn ->
            send(test, {:blob, conn.host, Plug.Conn.get_req_header(conn, "authorization")})
            Plug.Conn.send_resp(conn, 200, @log)
          end
        }
      )
    )

    assert :ok = perform_job(FetchLog, %{job_id: job.id, attempt: 0})
    assert_received {:blob, "blob.example", []}

    lines = Logs.lines(:job, job.id, 1, 100)

    assert Enum.map(lines, &{&1.n, &1.step_ref, &1.text}) == [
             {1, "step-1", "Current runner version: '2.330.0'"},
             {2, "step-1", "##[group]Operating System"},
             {3, "step-1", "##[endgroup]"},
             {4, "step-2", "\e[32mok\e[0m 12 tests"},
             {5, "step-2", "a line without a timestamp"},
             {6, "step-2", "done"}
           ]

    assert hd(lines).t == DateTime.to_unix(~U[2026-11-03 10:00:05.100Z], :millisecond)
    assert Jobs.get_job!(job.id).log_source == "github"
    assert Logs.last_n(:job, job.id) == 6
    index = Logs.index(:job, job.id)
    assert index.steps == %{"step-1" => 1, "step-2" => 4}
    assert index.groups == [[2, 3, "Operating System"]]
  end

  test "a 404 is tried again at 15, 60 and 180 s; then the live log is all there is", %{
    job: job,
    repo: repo
  } do
    GitHubStub.stub(routes(repo, {404, %{"message" => "Not Found"}}))

    for {attempt, wait} <- [{0, 10}, {1, 45}, {2, 120}] do
      assert :ok = perform_job(FetchLog, %{job_id: job.id, attempt: attempt})

      assert_enqueued(
        worker: FetchLog,
        args: %{job_id: job.id, attempt: attempt + 1},
        scheduled_at: {DateTime.add(DateTime.utc_now(), wait), delta: 3}
      )
    end

    assert :ok = perform_job(FetchLog, %{job_id: job.id, attempt: 3})
    assert Jobs.get_job!(job.id).log_source == "live"
    refute File.exists?(Logs.path(:job, job.id))
  end

  test "a log over the size limit is cut, with a marker", %{job: job, repo: repo} do
    Application.put_env(:crew, :log_limit_bytes, 200)
    on_exit(fn -> Application.delete_env(:crew, :log_limit_bytes) end)
    big = Enum.map_join(1..50, "", &"2026-11-03T10:00:07.000Z line #{&1}\n")
    GitHubStub.stub(routes(repo, fn conn -> Plug.Conn.send_resp(conn, 200, big) end))

    assert :ok = perform_job(FetchLog, %{job_id: job.id, attempt: 0})
    texts = Enum.map(Logs.lines(:job, job.id, 1, 100), & &1.text)
    assert length(texts) < 50
    assert List.last(texts) =~ "cut at"
  end
end
