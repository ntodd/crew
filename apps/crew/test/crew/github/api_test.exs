defmodule Crew.GitHub.APITest do
  use Crew.DataCase

  alias Crew.GitHub.{Client, InstallationTokens}
  alias Crew.GitHubStub

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
    InstallationTokens.clear()
    Crew.GitHub.Budget.reset()
    :ok
  end

  defp token_route(test_pid, token, expires_in) do
    %{
      {"POST", "/app/installations/77/access_tokens"} => fn conn ->
        send(test_pid, :token_issued)

        GitHubStub.json(conn, 201, %{
          "token" => token,
          "expires_at" => DateTime.utc_now() |> DateTime.add(expires_in) |> DateTime.to_iso8601()
        })
      end
    }
  end

  defp stub(test_pid, routes, token \\ "ghs_one", expires_in \\ 3600),
    do: GitHubStub.stub(Map.merge(token_route(test_pid, token, expires_in), routes))

  test "installation tokens are cached until they're nearly expired" do
    pid = self()

    stub(pid, %{
      {"GET", "/repos/acme/app/actions/runs/5/attempts/1"} => fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghs_one"]
        GitHubStub.json(conn, 200, %{"id" => 5})
      end
    })

    assert {:ok, %{"id" => 5}} = Client.get_run_attempt(77, "acme/app", 5, 1)
    assert {:ok, %{"id" => 5}} = Client.get_run_attempt(77, "acme/app", 5, 1)
    assert_received :token_issued
    refute_received :token_issued
  end

  test "a token with under five minutes left is replaced" do
    pid = self()

    stub(
      pid,
      %{{"GET", "/repos/acme/app/actions/runs/5/attempts/1"} => {200, %{}}},
      "ghs_short",
      200
    )

    {:ok, _} = Client.get_run_attempt(77, "acme/app", 5, 1)
    {:ok, _} = Client.get_run_attempt(77, "acme/app", 5, 1)
    assert_received :token_issued
    assert_received :token_issued
  end

  test "a 401 drops the cached token and tries once more" do
    pid = self()
    calls = :counters.new(1, [])

    stub(pid, %{
      {"GET", "/repos/acme/app/actions/runs/5/attempts/1"} => fn conn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: GitHubStub.json(conn, 401, %{"message" => "Bad credentials"}),
          else: GitHubStub.json(conn, 200, %{"id" => 5})
      end
    })

    assert {:ok, %{"id" => 5}} = Client.get_run_attempt(77, "acme/app", 5, 1)
    assert :counters.get(calls, 1) == 2
  end

  test "rate-limit headers feed the budget" do
    pid = self()

    stub(pid, %{
      {"GET", "/repos/acme/app/actions/runs/5/attempts/1"} => fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "123")
        |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", "#{System.os_time(:second) + 600}")
        |> GitHubStub.json(200, %{})
      end
    })

    {:ok, _} = Client.get_run_attempt(77, "acme/app", 5, 1)
    assert %{remaining: 123, limit: 5000} = Crew.GitHub.Budget.info(77)

    # Under 20%: optional calls are skipped without a request.
    assert {:error, :skipped} = Client.get_job(77, "acme/app", 9, class: :optional)
  end

  test "a transient failure on a read is retried through the budget, and writes aren't retried" do
    pid = self()
    reads = :counters.new(1, [])
    writes = :counters.new(1, [])

    stub(pid, %{
      {"GET", "/repos/acme/app/actions/jobs/9"} => fn conn ->
        :counters.add(reads, 1, 1)

        if :counters.get(reads, 1) < 3,
          do: GitHubStub.json(conn, 502, %{}),
          else: GitHubStub.json(conn, 200, %{"id" => 9})
      end,
      {"POST", "/repos/acme/app/actions/runs/5/cancel"} => fn conn ->
        :counters.add(writes, 1, 1)
        GitHubStub.json(conn, 502, %{})
      end
    })

    assert {:ok, %{"id" => 9}} = Client.get_job(77, "acme/app", 9)
    assert :counters.get(reads, 1) == 3
    assert {:error, {:http, 502, _}} = Client.cancel_run(77, "acme/app", 5)
    assert :counters.get(writes, 1) == 1
  end

  test "a 429 during retries backs off everyone" do
    pid = self()

    stub(pid, %{
      {"GET", "/repos/acme/app/actions/jobs/9"} => fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "30") |> GitHubStub.json(429, %{})
      end
    })

    assert {:error, _} = Client.get_job(77, "acme/app", 9)
    assert {:error, {:backoff, _}} = Client.get_job(77, "acme/app", 10, class: :essential)
  end

  test "lists are paginated" do
    pid = self()

    stub(pid, %{
      {"GET", "/repos/acme/app/actions/runs/5/attempts/1/jobs"} => fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"])
        jobs = if page == 1, do: Enum.map(1..100, &%{"id" => &1}), else: [%{"id" => 101}]
        GitHubStub.json(conn, 200, %{"total_count" => 101, "jobs" => jobs})
      end
    })

    assert {:ok, jobs} = Client.list_attempt_jobs(77, "acme/app", 5, 1)
    assert length(jobs) == 101
  end

  test "requests emit telemetry with the endpoint, not the ids" do
    pid = self()
    stub(pid, %{{"GET", "/repos/acme/app/actions/jobs/9"} => {200, %{}}})
    ref = :telemetry_test.attach_event_handlers(self(), [[:crew, :github, :request]])

    {:ok, _} = Client.get_job(77, "acme/app", 9)

    assert_received {[:crew, :github, :request], ^ref, %{duration: _},
                     %{
                       endpoint: "GET /repos/{o}/{r}/actions/jobs/{id}",
                       status: 200,
                       class: :normal
                     }}
  end
end
