defmodule CrewWeb.HookEndpointTest do
  use Crew.DataCase
  use Oban.Testing, repo: Crew.Repo

  import Plug.Test
  import Plug.Conn

  alias Crew.GitHub.Webhook

  @secret "hook-secret-for-tests"

  setup do
    Application.put_env(:crew, :github_app, %{webhook_secret: @secret})
    on_exit(fn -> Application.delete_env(:crew, :github_app) end)
    # A fresh client address per test: the failure limiter is in ETS.
    %{ip: "100.64.#{:rand.uniform(250)}.#{:rand.uniform(250)}"}
  end

  defp deliver(body, opts \\ []) do
    signature = Keyword.get_lazy(opts, :signature, fn -> Webhook.sign(body, @secret) end)

    conn(:post, Keyword.get(opts, :path, "/hooks/github"), body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", Keyword.get(opts, :event, "workflow_job"))
    |> put_req_header("x-github-delivery", Keyword.get(opts, :delivery, Ecto.UUID.generate()))
    |> then(&if signature, do: put_req_header(&1, "x-hub-signature-256", signature), else: &1)
    |> then(&if opts[:ip], do: put_req_header(&1, "x-forwarded-for", opts[:ip]), else: &1)
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> CrewWeb.HookEndpoint.call(CrewWeb.HookEndpoint.init([]))
  end

  @payload ~s({"action":"queued","workflow_job":{"id":42}})

  test "a signed delivery is recorded and queued, and answered 202" do
    conn = deliver(@payload, delivery: "d-1")
    assert conn.status == 202

    assert [%{github_delivery_id: "d-1", event: "workflow_job", action: "queued"}] =
             Repo.all(
               from d in "webhook_deliveries",
                 select: %{
                   github_delivery_id: d.github_delivery_id,
                   event: d.event,
                   action: d.action
                 }
             )

    assert_enqueued(
      worker: Crew.GitHub.HookWorker,
      args: %{
        "event" => "workflow_job",
        "action" => "queued",
        "delivery_id" => "d-1",
        "object_id" => "42"
      }
    )
  end

  test "the same delivery twice is answered 200 and queued once" do
    assert deliver(@payload, delivery: "d-2").status == 202
    assert deliver(@payload, delivery: "d-2").status == 200
    assert length(all_enqueued(worker: Crew.GitHub.HookWorker)) == 1
  end

  test "a bad signature is 401, and nothing is recorded" do
    assert deliver(@payload, signature: "sha256=" <> String.duplicate("0", 64)).status == 401
    assert deliver(@payload, signature: nil).status == 401
    assert Repo.aggregate("webhook_deliveries", :count) == 0
    refute_enqueued(worker: Crew.GitHub.HookWorker)
  end

  test "failures are rate-limited per client at 60 a minute", %{ip: ip} do
    bad = "sha256=" <> String.duplicate("0", 64)
    for _ <- 1..60, do: assert(deliver(@payload, signature: bad, ip: ip).status == 401)
    assert deliver(@payload, signature: bad, ip: ip).status == 429

    # Another client isn't affected.
    assert deliver(@payload, signature: bad, ip: "100.64.0.1").status == 401
  end

  test "correctly signed requests are never rate-limited", %{ip: ip} do
    bad = "sha256=" <> String.duplicate("0", 64)
    for _ <- 1..61, do: deliver(@payload, signature: bad, ip: ip)
    assert deliver(@payload, ip: ip).status == 202
  end

  test "a body over 5 MiB is refused before it's read" do
    conn =
      conn(:post, "/hooks/github", "")
      |> put_req_header("content-length", Integer.to_string(5 * 1024 * 1024 + 1))
      |> CrewWeb.HookEndpoint.call([])

    assert conn.status == 413
  end

  test "a body over 5 MiB without a content-length is refused too" do
    big = String.duplicate("a", 5 * 1024 * 1024 + 10)
    assert deliver(big).status == 413
  end

  test "it has exactly one route" do
    assert deliver(@payload, path: "/").status == 404
    assert deliver(@payload, path: "/hooks/github/x").status == 404

    conn = conn(:get, "/hooks/github") |> CrewWeb.HookEndpoint.call([])
    assert conn.status == 404
  end

  test "a signed body that isn't JSON, or missing headers, is 400" do
    assert deliver("not json").status == 400

    conn =
      conn(:post, "/hooks/github", @payload)
      |> put_req_header("x-hub-signature-256", Webhook.sign(@payload, @secret))
      |> CrewWeb.HookEndpoint.call([])

    assert conn.status == 400
  end

  test "no webhook secret configured refuses everything" do
    Application.put_env(:crew, :github_app, %{})
    assert deliver(@payload).status == 401
  end
end
