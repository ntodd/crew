defmodule CrewGuest.HookTest do
  @moduledoc "The fork-PR job-started hook, images/guest/hooks/job-started (§19.5)."
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.{EnvFile, FakeAPI}

  @moduletag :tmp_dir

  @hook Path.expand("../../../../images/guest/hooks/job-started", __DIR__)
  @refused "Crew: fork PRs are refused on this repo"
  @pr_events ~w(pull_request pull_request_target pull_request_review pull_request_review_comment)

  setup %{tmp_dir: run_dir} do
    api = start_supervised!(FakeAPI)

    File.write!(
      Path.join(run_dir, "guest.env"),
      EnvFile.shell([{"CREW_API", FakeAPI.url(api)}, {"CREW_TOKEN", "t0ken"}])
    )

    %{api: api, run_dir: run_dir}
  end

  defp policy(run_dir, fork_prs) do
    File.write!(
      Path.join(run_dir, "policy.json"),
      Jason.encode!(%{"fork_prs" => fork_prs, "repo_full_name" => "ntodd/crew"})
    )
  end

  defp hook(run_dir, event_name, event) do
    path = if event, do: fixture("events/#{event}.json"), else: Path.join(run_dir, "missing.json")

    System.cmd("sh", [@hook, run_dir],
      env: [{"GITHUB_EVENT_NAME", event_name}, {"GITHUB_EVENT_PATH", path}],
      stderr_to_stdout: true
    )
  end

  test "refuses a fork PR, says why and reports job_refused", %{api: api, run_dir: run_dir} do
    policy(run_dir, "refuse")

    assert {out, 1} = hook(run_dir, "pull_request", "pull_request_fork")
    assert String.trim(out) == @refused

    assert [req] = FakeAPI.requests(api, "/v1/state")
    assert req.auth == "Bearer t0ken"
    assert %{state: "job_refused", detail: "fork_pr"} = req.cast
    assert is_integer(req.json["at"]) and req.json["at"] > 1_700_000_000_000
  end

  test "refuses a fork for every pull request event", %{run_dir: run_dir} do
    policy(run_dir, "refuse")

    for event <- @pr_events do
      assert {_out, 1} = hook(run_dir, event, "pull_request_fork"), event
    end
  end

  test "refuses a PR whose head repo is gone (null)", %{run_dir: run_dir} do
    policy(run_dir, "refuse")
    assert {_out, 1} = hook(run_dir, "pull_request", "pull_request_deleted_fork")
  end

  test "lets a PR from the repo itself run", %{api: api, run_dir: run_dir} do
    policy(run_dir, "refuse")

    for event <- @pr_events do
      assert {"", 0} = hook(run_dir, event, "pull_request_same_repo"), event
    end

    assert FakeAPI.requests(api) == []
  end

  test "lets fork PRs run when the policy allows them", %{run_dir: run_dir} do
    policy(run_dir, "allow")
    assert {"", 0} = hook(run_dir, "pull_request", "pull_request_fork")
  end

  test "behaves the same under `bash -e`, which is how the runner runs hooks",
       %{run_dir: run_dir} do
    policy(run_dir, "refuse")

    run = fn event ->
      System.cmd("bash", ["-e", @hook, run_dir],
        env: [
          {"GITHUB_EVENT_NAME", "pull_request"},
          {"GITHUB_EVENT_PATH", fixture("events/#{event}.json")}
        ],
        stderr_to_stdout: true
      )
    end

    assert {_out, 1} = run.("pull_request_fork")
    assert {"", 0} = run.("pull_request_same_repo")
  end

  test "ignores events that aren't pull requests", %{run_dir: run_dir} do
    policy(run_dir, "refuse")
    assert {"", 0} = hook(run_dir, "push", "push")
    assert {"", 0} = hook(run_dir, "workflow_dispatch", "push")
    assert {"", 0} = hook(run_dir, "", nil)
  end

  describe "fails closed" do
    test "a missing or unreadable policy counts as refuse", %{run_dir: run_dir} do
      assert {_out, 1} = hook(run_dir, "pull_request", "pull_request_fork")
      assert {"", 0} = hook(run_dir, "pull_request", "pull_request_same_repo")

      File.write!(Path.join(run_dir, "policy.json"), "{not json")
      assert {_out, 1} = hook(run_dir, "pull_request", "pull_request_fork")
    end

    test "a missing event payload counts as a fork", %{run_dir: run_dir} do
      policy(run_dir, "refuse")
      assert {_out, 1} = hook(run_dir, "pull_request", nil)
    end

    test "an event with no repository names counts as a fork", %{run_dir: run_dir} do
      policy(run_dir, "refuse")
      event = Path.join(run_dir, "event.json")
      File.write!(event, ~s({"pull_request": {"head": {"repo": {}}}, "repository": {}}))

      assert {_out, 1} =
               System.cmd("sh", [@hook, run_dir],
                 env: [{"GITHUB_EVENT_NAME", "pull_request"}, {"GITHUB_EVENT_PATH", event}],
                 stderr_to_stdout: true
               )
    end

    test "it still refuses when the guest API can't be reached", %{run_dir: run_dir} do
      policy(run_dir, "refuse")

      File.write!(
        Path.join(run_dir, "guest.env"),
        EnvFile.shell([{"CREW_API", "http://127.0.0.1:1"}])
      )

      assert {out, 1} = hook(run_dir, "pull_request", "pull_request_fork")
      assert String.trim(out) == @refused

      File.rm!(Path.join(run_dir, "guest.env"))
      assert {_out, 1} = hook(run_dir, "pull_request", "pull_request_fork")
    end
  end
end
