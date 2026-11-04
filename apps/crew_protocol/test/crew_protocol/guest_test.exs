defmodule CrewProtocol.GuestTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.Guest

  # The VM's lifetime, in Unix milliseconds.
  @life {1_000_000, 2_000_000}

  describe "state" do
    test "a valid state" do
      assert Guest.cast_state(%{"state" => "runner_listening", "at" => 1_500_000}, @life) ==
               {:ok, %{state: "runner_listening", at: 1_500_000, detail: nil}}
    end

    test "unknown fields are dropped, not refused" do
      assert {:ok, state} =
               Guest.cast_state(%{"state" => "job_started", "at" => 1_500_000, "x" => 1}, @life)

      refute Map.has_key?(state, :x)
    end

    test "only the guest's own states are taken" do
      for state <- ~w(runner_listening job_started job_finished job_refused) do
        assert {:ok, _} = Guest.cast_state(%{"state" => state}, @life), state
      end

      # booted comes from the agent (the payload fetch), never from the guest.
      assert {:error, _} = Guest.cast_state(%{"state" => "booted"}, @life)
      assert {:error, _} = Guest.cast_state(%{"state" => "idle"}, @life)
      assert {:error, _} = Guest.cast_state("nope", @life)
    end

    test "timestamps are clamped to the VM's lifetime, and default to its end" do
      assert {:ok, %{at: 1_000_000}} =
               Guest.cast_state(%{"state" => "job_started", "at" => 5}, @life)

      assert {:ok, %{at: 2_000_000}} =
               Guest.cast_state(%{"state" => "job_started", "at" => 9_999_999_999}, @life)

      assert {:ok, %{at: 2_000_000}} = Guest.cast_state(%{"state" => "job_started"}, @life)

      assert {:ok, %{at: 2_000_000}} =
               Guest.cast_state(%{"state" => "job_started", "at" => "soon"}, @life)
    end

    test "detail is capped at 1 KiB on a UTF-8 boundary" do
      detail = String.duplicate("é", 600)

      assert {:ok, %{detail: d}} =
               Guest.cast_state(%{"state" => "job_finished", "detail" => detail}, @life)

      assert byte_size(d) <= 1024
      assert String.valid?(d)
    end

    test "detail that isn't text becomes nil" do
      assert {:ok, %{detail: nil}} =
               Guest.cast_state(%{"state" => "job_finished", "detail" => %{"a" => 1}}, @life)
    end
  end

  describe "steps" do
    @step %{
      "ref" => "step-1",
      "name" => "Run tests",
      "number" => 3,
      "status" => "in_progress",
      "started_at" => 1_200_000,
      "completed_at" => nil,
      "conclusion" => nil,
      "extra" => true
    }

    test "valid steps, with unknown fields dropped" do
      assert {:ok, [step]} = Guest.cast_steps(%{"steps" => [@step]}, @life)
      assert step.ref == "step-1"
      assert step.status == "in_progress"
      refute Map.has_key?(step, :extra)
    end

    test "at most 1000 steps" do
      assert {:error, :too_many_steps} =
               Guest.cast_steps(%{"steps" => List.duplicate(@step, 1001)}, @life)
    end

    test "a step with a bad ref is dropped" do
      bad = %{@step | "ref" => "a b"}
      assert {:ok, [_]} = Guest.cast_steps(%{"steps" => [bad, @step]}, @life)
    end

    test "status and conclusion come from fixed lists" do
      assert {:ok, [%{status: "pending", conclusion: nil}]} =
               Guest.cast_steps(
                 %{"steps" => [%{@step | "status" => "weird", "conclusion" => "meh"}]},
                 @life
               )
    end

    test "an empty name falls back to the ref" do
      assert {:ok, [%{name: "step-1"}]} =
               Guest.cast_steps(%{"steps" => [%{@step | "name" => ""}]}, @life)
    end

    test "cleaned steps are always a valid vm.steps event" do
      steps = [%{@step | "name" => ""}, %{"ref" => "x"}, %{@step | "status" => 1}]
      {:ok, cleaned} = Guest.cast_steps(%{"steps" => steps}, @life)
      vm_id = CrewProtocol.Examples.vm_id()

      assert {:ok, _} =
               CrewProtocol.Event.new("vm.steps", %{
                 "vm_id" => vm_id,
                 "steps" => Enum.map(cleaned, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
               })
    end

    test "names are capped and timestamps clamped" do
      step = %{@step | "name" => String.duplicate("n", 2000), "started_at" => 1}
      assert {:ok, [s]} = Guest.cast_steps(%{"steps" => [step]}, @life)
      assert byte_size(s.name) <= 512
      assert s.started_at == 1_000_000
    end
  end

  describe "log lines" do
    test "a valid line" do
      assert Guest.cast_log_line(%{"t" => 1_500_000, "step_ref" => "s1", "text" => "hi"}, @life) ==
               {:ok, %{t: 1_500_000, step_ref: "s1", text: "hi", truncated: false}}
    end

    test "text over 64 KiB is cut at a UTF-8 boundary and marked truncated" do
      text = String.duplicate("ü", 40_000)
      assert {:ok, line} = Guest.cast_log_line(%{"text" => text, "step_ref" => "s"}, @life)
      assert byte_size(line.text) <= 65_536
      assert String.valid?(line.text)
      assert line.truncated
    end

    test "invalid UTF-8 and NUL bytes are replaced" do
      assert {:ok, %{text: text}} =
               Guest.cast_log_line(
                 %{"text" => <<"a", 0xFF, "b", 0, "c">>, "step_ref" => "s"},
                 @life
               )

      assert String.valid?(text)
      refute String.contains?(text, <<0>>)
    end

    test "a bad step ref is refused" do
      assert {:error, _} = Guest.cast_log_line(%{"text" => "x", "step_ref" => "<script>"}, @life)
    end

    test "a missing step ref is nil" do
      assert {:ok, %{step_ref: nil}} = Guest.cast_log_line(%{"text" => "x"}, @life)
    end

    test "parse_ndjson/2 reads a body of lines, skipping bad ones" do
      body =
        Enum.map_join(
          [%{"text" => "a", "t" => 1_100_000}, "junk", %{"text" => "b"}],
          "\n",
          fn
            "junk" -> "{not json"
            m -> Jason.encode!(m)
          end
        ) <> "\n"

      assert {:ok, [%{text: "a"}, %{text: "b"}], 1} = Guest.parse_ndjson(body, @life)
    end
  end

  describe "metrics" do
    test "a valid sample, clamped and capped" do
      body = %{
        "t" => 3_000_000,
        "cpu_pct" => 250.0,
        "mem_used_mib" => 100,
        "mem_total_mib" => 8192,
        "disk_used_mib" => 10,
        "net_rx_bytes" => 5,
        "net_tx_bytes" => 6
      }

      assert {:ok, m} = Guest.cast_metrics(body, @life)
      assert m.t == 2_000_000
      assert m.cpu_pct == 100.0
      assert m.net_rx_bytes == 5
    end

    test "an enormous number doesn't crash" do
      huge = Integer.pow(10, 400)
      assert {:ok, m} = Guest.cast_metrics(%{"cpu_pct" => huge, "mem_used_mib" => huge}, @life)
      assert m.cpu_pct == 100.0
    end

    test "missing or negative numbers become 0" do
      assert {:ok, m} = Guest.cast_metrics(%{"mem_used_mib" => -5}, @life)
      assert m.mem_used_mib == 0
      assert m.cpu_pct == 0.0
    end
  end

  describe "payload" do
    test "the payload body has the documented fields" do
      payload =
        Guest.payload(%{
          jit_config: "abc",
          ca_pem: "-----BEGIN CERTIFICATE-----",
          policy: %{fork_prs: "refuse", repo_full_name: "o/r"},
          size: %{vcpus: 4, memory_mib: 8192, disk_gib: 60},
          labels: ["crew-m"]
        })

      assert Map.keys(payload) |> Enum.sort() ==
               ~w(ca_pem jit_config labels mirrors policy size)

      assert payload["policy"] == %{"fork_prs" => "refuse", "repo_full_name" => "o/r"}
      # No cache, no mirrors.
      assert payload["mirrors"] == []
    end

    test "the registries the box's cache mirrors (§15.1, Design A), known hosts only" do
      payload =
        Guest.payload(%{
          jit_config: "abc",
          ca_pem: "pem",
          policy: %{fork_prs: "refuse", repo_full_name: "o/r"},
          size: %{vcpus: 4, memory_mib: 8192, disk_gib: 60},
          labels: ["crew-m"],
          mirrors: ["ghcr.io", "evil.example", "registry-1.docker.io"]
        })

      assert payload["mirrors"] == ["ghcr.io", "registry-1.docker.io"]
    end

    test "carries a conformance object only when it's given one, and only a valid one" do
      base = %{
        jit_config: "abc",
        ca_pem: "",
        policy: %{fork_prs: "refuse", repo_full_name: "o/r"},
        size: %{vcpus: 4, memory_mib: 8192, disk_gib: 60},
        labels: ["crew-m"]
      }

      refute Map.has_key?(Guest.payload(base), "conformance")
      refute Map.has_key?(Guest.payload(Map.put(base, :conformance, nil)), "conformance")

      {:ok, c} = Guest.cast_conformance(%{"checks" => ["sizing"]})
      assert Guest.payload(Map.put(base, :conformance, c))["conformance"] == c

      assert_raise ArgumentError, fn ->
        Guest.payload(Map.put(base, :conformance, %{"checks" => ["rm -rf /"]}))
      end
    end
  end

  describe "conformance (§11.6)" do
    @good %{
      "checks" => ["sizing", "isolation", "api_flood"],
      "targets" => [%{"label" => "host-ssh", "ip" => "192.168.64.34", "port" => 22}],
      "reach" => [%{"label" => "guest-api", "ip" => "10.199.0.1", "port" => 7777}],
      "peers" => ["10.200.0.6"],
      "foreign_tokens" => [String.duplicate("A", 43)],
      "listen_port" => 9000,
      "hold_s" => 30,
      "ticks" => 50,
      "console_mib" => 100,
      "conntrack" => %{"ip" => "10.199.0.1", "port" => 7777, "count" => 2100}
    }

    test "a valid object comes back as it went in" do
      assert Guest.cast_conformance(@good) == {:ok, @good}
      assert {:ok, %{"checks" => []}} = Guest.cast_conformance(%{"checks" => []})
    end

    test "checks are names from a fixed list: nothing that could be a command" do
      for bad <- ["rm -rf /", "sizing;id", "../check", "SIZING", "", 1] do
        assert {:error, _} = Guest.cast_conformance(%{"checks" => [bad]}), inspect(bad)
      end
    end

    test "unknown fields are refused, not dropped" do
      for key <- ["script", "command", "cmd", "env", "args"] do
        assert {:error, reasons} = Guest.cast_conformance(Map.put(@good, key, "/bin/sh"))
        assert Enum.any?(reasons, &(&1 =~ key))
      end

      target = %{"label" => "x", "ip" => "1.2.3.4", "port" => 1, "proto" => "sh"}
      assert {:error, _} = Guest.cast_conformance(%{"checks" => [], "targets" => [target]})
    end

    test "addresses must be IPv4, ports and counts in range, labels and tokens plain" do
      bad = [
        {"targets", [%{"label" => "x", "ip" => "1.2.3.4; id", "port" => 22}]},
        {"targets", [%{"label" => "x", "ip" => "::1", "port" => 22}]},
        {"targets", [%{"label" => "x", "ip" => "1.2.3.4", "port" => 0}]},
        {"targets", [%{"label" => "x", "ip" => "1.2.3.4", "port" => 65_536}]},
        {"targets", [%{"label" => "$(id)", "ip" => "1.2.3.4", "port" => 22}]},
        {"targets", [%{"label" => "x y", "ip" => "1.2.3.4", "port" => 22}]},
        {"targets", for(i <- 1..65, do: %{"label" => "t#{i}", "ip" => "1.2.3.4", "port" => 1})},
        {"peers", ["10.200.0.6/30"]},
        {"peers", ["010.200.0.6"]},
        {"foreign_tokens", ["tok en"]},
        {"foreign_tokens", ["short"]},
        {"listen_port", 80},
        {"hold_s", 3601},
        {"hold_s", "30"},
        {"ticks", -1},
        {"console_mib", 101},
        {"conntrack", %{"ip" => "10.199.0.1", "port" => 7777, "count" => 5000}},
        {"conntrack", %{"ip" => "10.199.0.1", "port" => 7777}}
      ]

      for {key, value} <- bad do
        assert {:error, _} = Guest.cast_conformance(Map.put(@good, key, value)),
               "#{key}: #{inspect(value)}"
      end
    end

    test "checks are required, and the object must be an object" do
      assert {:error, _} = Guest.cast_conformance(%{})
      assert {:error, _} = Guest.cast_conformance("sizing")
      assert {:error, _} = Guest.cast_conformance(nil)
    end
  end
end
