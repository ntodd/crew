defmodule Crew.GitHub.WebhookTest do
  use ExUnit.Case, async: true

  alias Crew.GitHub.Webhook

  # GitHub's own test vector (docs: "Validating webhook deliveries").
  @secret "It's a Secret to Everybody"
  @payload "Hello, World!"
  @signature "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"

  test "GitHub's test vector verifies" do
    assert Webhook.verify(@payload, @signature, @secret) == :ok
  end

  test "signing is the inverse of verifying" do
    assert Webhook.sign(@payload, @secret) == @signature
  end

  test "the wrong secret, body or a tampered signature is refused" do
    assert Webhook.verify(@payload, @signature, "another secret") == :error
    assert Webhook.verify(@payload <> " ", @signature, @secret) == :error
    assert Webhook.verify(@payload, String.replace(@signature, "7", "8"), @secret) == :error
  end

  test "a missing, malformed or sha1 signature is refused" do
    assert Webhook.verify(@payload, nil, @secret) == :error
    assert Webhook.verify(@payload, "", @secret) == :error
    assert Webhook.verify(@payload, "sha256=zz", @secret) == :error

    assert Webhook.verify(@payload, "sha1=757107ea0eb2509fc211221cce984b8a37570b6d", @secret) ==
             :error
  end

  test "no secret configured refuses everything" do
    assert Webhook.verify(@payload, @signature, nil) == :error
    assert Webhook.verify(@payload, @signature, "") == :error
  end

  describe "object_id/3" do
    test "is the job, or the run attempt, the event is about" do
      assert Webhook.object_id("workflow_job", %{"workflow_job" => %{"id" => 5}}, "d") == "5"

      assert Webhook.object_id(
               "workflow_run",
               %{"workflow_run" => %{"id" => 6, "run_attempt" => 2}},
               "d"
             ) ==
               "6/2"
    end

    test "a re-run's attempt is a different object" do
      refute Webhook.object_id(
               "workflow_run",
               %{"workflow_run" => %{"id" => 6, "run_attempt" => 1}},
               "d"
             ) ==
               Webhook.object_id(
                 "workflow_run",
                 %{"workflow_run" => %{"id" => 6, "run_attempt" => 2}},
                 "d"
               )
    end

    test "installation changes are each their own, by delivery" do
      assert Webhook.object_id(
               "installation_repositories",
               %{"installation" => %{"id" => 8}},
               "d1"
             ) == "d1"

      assert Webhook.object_id("installation", %{"installation" => %{"id" => 7}}, "d2") == "d2"
      assert Webhook.object_id("star", %{}, "d3") == "d3"
    end
  end
end
