defmodule CrewWeb.RunActionsTest do
  @moduledoc "The run page's actions and jobs table (§17.3): cancel and re-runs need can_push, and are audited."
  use CrewWeb.ConnCase

  import Ecto.Query

  alias Crew.{GitHubStub, Jobs, Repo}

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

    repo = repo_fixture(name: "app")

    {:ok, _} =
      Jobs.handle_workflow_run(workflow_run_payload(repo, id: 700, status: "in_progress"))

    for {id, name, conclusion} <- [
          {71, "test (1)", "success"},
          {72, "test (2)", "failure"},
          {73, "lint", nil}
        ] do
      status = if conclusion, do: "completed", else: "in_progress"

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: id,
            run_id: 700,
            name: name,
            status: status,
            conclusion: conclusion
          )
        )
    end

    %{repo: repo}
  end

  defp stub(repo, test) do
    inst = repo.installation.github_id

    GitHubStub.stub(%{
      {"POST", "/app/installations/#{inst}/access_tokens"} =>
        {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}},
      {"POST", "/repos/#{repo.full_name}/actions/runs/700/cancel"} => fn conn ->
        send(test, :cancel)
        GitHubStub.json(conn, 202, %{})
      end,
      {"POST", "/repos/#{repo.full_name}/actions/runs/700/rerun"} => fn conn ->
        send(test, :rerun)
        GitHubStub.json(conn, 201, %{})
      end,
      {"POST", "/repos/#{repo.full_name}/actions/runs/700/rerun-failed-jobs"} => fn conn ->
        send(test, :rerun_failed)
        GitHubStub.json(conn, 201, %{})
      end
    })
  end

  defp audited?(action), do: Repo.exists?(from e in Crew.Audit.Event, where: e.action == ^action)

  test "an admin cancels a running run, audited", %{conn: conn, repo: repo} do
    stub(repo, self())
    {:ok, view, _} = live(log_in(conn, user_fixture(role: "admin")), ~p"/runs/700/attempts/1")
    view |> element("#cancel-run") |> render_click()
    assert_received :cancel
    assert audited?("run.cancel")
    assert render(view) =~ "Cancelling"
  end

  test "a finished run offers both re-runs", %{conn: conn, repo: repo} do
    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 73,
          run_id: 700,
          name: "lint",
          status: "completed",
          conclusion: "success"
        )
      )

    {:ok, _} =
      Jobs.handle_workflow_run(
        workflow_run_payload(repo, id: 700, status: "completed", conclusion: "failure")
      )

    stub(repo, self())
    {:ok, view, _} = live(log_in(conn, user_fixture(role: "admin")), ~p"/runs/700/attempts/1")

    refute has_element?(view, "#cancel-run")
    view |> element("#rerun-failed") |> render_click()
    assert_received :rerun_failed
    view |> element("#rerun-all") |> render_click()
    assert_received :rerun
    assert audited?("run.rerun_failed") and audited?("run.rerun")
  end

  test "members without push access see no actions, and can't send them", %{
    conn: conn,
    repo: repo
  } do
    member = user_fixture()

    Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      can_push: false,
      checked_at: DateTime.utc_now()
    })

    stub(repo, self())
    {:ok, view, _} = live(log_in(conn, member), ~p"/runs/700/attempts/1")

    refute has_element?(view, "#cancel-run")
    render_click(view, "cancel", %{})
    refute_received :cancel
    refute audited?("run.cancel")
  end

  test "members with push access can", %{conn: conn, repo: repo} do
    member = user_fixture()

    Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      can_push: true,
      checked_at: DateTime.utc_now()
    })

    stub(repo, self())
    {:ok, view, _} = live(log_in(conn, member), ~p"/runs/700/attempts/1")
    view |> element("#cancel-run") |> render_click()
    assert_received :cancel
  end

  test "jobs are grouped by matrix prefix, with size, box and times", %{conn: conn} do
    {:ok, view, _} = live(log_in(conn, user_fixture(role: "admin")), ~p"/runs/700/attempts/1")
    assert has_element?(view, "#group-test", "test (1)")
    assert has_element?(view, "#group-test", "test (2)")
    assert has_element?(view, "#group-lint", "lint")
    assert has_element?(view, "#job-71 [data-col=size]", "m")
  end
end
