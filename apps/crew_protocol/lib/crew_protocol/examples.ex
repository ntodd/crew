defmodule CrewProtocol.Examples do
  @moduledoc """
  A valid wire payload for every command and event, and for the join.

  The contract tests on every side start from these, so a field added to
  a spec has to be added here too.
  """

  @vm_id "0190f0a2-7b1c-7d2e-8f3a-1b2c3d4e5f60"
  @image_id "0190f0a2-0000-7000-8000-00000000a001"
  @op_id "0190f0a2-0000-7000-8000-00000000b001"
  @boot_id "6c1b8f0e-3a52-4f5e-9d0a-2b7e4c9f1a33"
  @sha String.duplicate("ab", 32)
  @sig Base.encode64(:binary.copy(<<7>>, 64))

  def vm_id, do: @vm_id
  def image_id, do: @image_id

  def join do
    %{
      "agent_version" => "0.1.0",
      "protocol_version" => CrewProtocol.version(),
      "box_name" => "m1ultra",
      "os" => "darwin",
      "arch" => "arm64",
      "boot_id" => @boot_id,
      "in_flight" => []
    }
  end

  def commands do
    %{
      "vm.start" => %{
        "vm_id" => @vm_id,
        "name" => "crew-ab12-m1ultra-2c3d4e5f60",
        "size" => %{"vcpus" => 4, "memory_mib" => 8192, "disk_gib" => 60, "limits" => %{}},
        "image" => %{
          "id" => @image_id,
          "version" => "0.1.0",
          "arch" => "arm64",
          "manifest_sha256" => @sha
        },
        "jit_config" => Base.encode64(~s({"runner":"jit"})),
        "labels" => ["crew-m"],
        "deadline" => 1_900_000_000,
        "log_limit_bytes" => 104_857_600,
        "policy" => %{"fork_prs" => "refuse", "repo_full_name" => "ntodd/crew"}
      },
      "vm.stop" => %{"vm_id" => @vm_id, "reason" => "reaped", "force" => false, "grace_s" => 30},
      "vm.log.ack" => %{"vm_id" => @vm_id, "epoch" => "0123456789abcdef", "seq" => 12},
      "vm.log.resend" => %{"vm_id" => @vm_id, "epoch" => "0123456789abcdef", "from_seq" => 4},
      "image.prepare" => %{
        "image" => %{
          "id" => @image_id,
          "version" => "0.1.0",
          "arch" => "arm64",
          "kernel" => %{
            "url" => "https://crew.example.ts.net/images/k",
            "sha256" => @sha,
            "size" => 10
          },
          "rootfs" => %{
            "url" => "https://crew.example.ts.net/images/r",
            "sha256" => @sha,
            "size" => 20
          },
          "manifest" => Base.encode64("{}"),
          "signature" => @sig
        }
      },
      "image.remove" => %{"image_id" => @image_id},
      "cache.config" => %{
        "enabled_hosts" => ["ghcr.io", "public.ecr.aws"],
        "allowlist" => ["ghcr.io/actions/*", "public.ecr.aws/docker/library/*"],
        "parent" => %{
          "url" => "https://service.example.ts.net:5443",
          "token" => "parent-token-0123456789",
          "ca_pem" => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
        },
        "rotate_ca" => false
      },
      "cache.purge" => %{"scope" => "host:ghcr.io"},
      "box.inventory" => %{},
      "box.restart" => %{"boot_id" => @boot_id, "force" => false},
      "cachevm.restart" => %{"boot_id" => @boot_id},
      "agent.update" => %{
        "version" => "0.2.0",
        "url" =>
          "https://crew.example.ts.net/agent/releases/0.2.0/linux-arm64/crew-agent-0.2.0-linux-arm64.tar.gz",
        "sha256" => @sha,
        "size" => 48_000_000,
        "signature" => @sig,
        "cache" => %{
          "url" =>
            "https://crew.example.ts.net/agent/releases/0.2.0/linux-arm64/crew-cache-0.2.0-linux-arm64.tar.gz",
          "sha256" => @sha,
          "size" => 24_000_000,
          "signature" => @sig
        }
      },
      "op.cancel" => %{"target_op_id" => @op_id}
    }
  end

  def events do
    %{
      "op.result" => %{"op_id" => @op_id, "status" => "ok", "result" => %{}},
      "vm.state" => %{
        "vm_id" => @vm_id,
        "state" => "runner_listening",
        "at" => 1_800_000_000_000,
        "detail" => "Listening for Jobs"
      },
      "vm.exited" => %{
        "vm_id" => @vm_id,
        "reason" => "poweroff",
        "exit_status" => 0,
        "uptime_ms" => 61_000,
        "cleanup" => "ok"
      },
      "vm.log" => %{
        "vm_id" => @vm_id,
        "epoch" => "0123456789abcdef",
        "seq" => 1,
        "lines" => [
          %{
            "n" => 1,
            "t" => 1_800_000_000_000,
            "step_ref" => "s1",
            "text" => "hello",
            "truncated" => false
          }
        ]
      },
      "vm.log.gone" => %{"vm_id" => @vm_id, "epoch" => "0123456789abcdef", "up_to_seq" => 3},
      "vm.steps" => %{
        "vm_id" => @vm_id,
        "steps" => [
          %{
            "ref" => "s1",
            "name" => "Set up job",
            "number" => 1,
            "status" => "completed",
            "started_at" => 1_800_000_000_000,
            "completed_at" => 1_800_000_001_000,
            "conclusion" => "success"
          }
        ]
      },
      "vm.metrics" => %{
        "vm_id" => @vm_id,
        "t" => 1_800_000_000_000,
        "cpu_pct" => 12.5,
        "mem_used_mib" => 900,
        "mem_total_mib" => 8192,
        "disk_used_mib" => 2048,
        "net_rx_bps" => 1000,
        "net_tx_bps" => 200,
        "host_cpu_pct" => 50.0,
        "host_rss_mib" => 1200
      },
      "box.metrics" => %{
        "t" => 1_800_000_000_000,
        "cpu_pct" => 30.0,
        "mem_used_mib" => 20_000,
        "mem_total_mib" => 110_592,
        "swap_used_mib" => 0,
        "load1" => 3.2,
        "disk_used_mib" => 100_000,
        "disk_total_mib" => 1_000_000,
        "vm_area_free_mib" => 400_000,
        "cache_used_mib" => 5000,
        "vms_running" => 2
      },
      "box.capabilities" => %{
        "driver" => "vz",
        "driver_version" => "0.1.0",
        "guest_arch" => "arm64",
        "vcpus" => 18,
        "memory_mib" => 110_592,
        "vm_area_mib" => 409_600,
        "max_vcpus_per_vm" => 18,
        "max_memory_mib_per_vm" => 110_592,
        "vmm_overhead_mib" => 128,
        "features" => ["graceful_stop"],
        "virtualized" => false,
        "hypervisor_vendor" => nil,
        "firewall_ok" => true,
        "sleep_disabled" => true
      },
      "box.inventory" => %{
        "vms" => [
          %{
            "vm_id" => @vm_id,
            "alive" => false,
            "since" => 1_800_000_000_000,
            "exited" => %{"reason" => "poweroff", "exit_status" => 0, "at" => 1_800_000_060_000}
          }
        ],
        "images" => [%{"id" => @image_id, "state" => "ready"}]
      },
      "box.reboot" => %{
        "required" => true,
        "packages" => ["flatcar-4230.2.1"],
        "boot_id" => @boot_id,
        "can_restart" => true,
        "os_version" => "4152.2.3",
        "cache_vm" => nil
      },
      "image.state" => %{"image_id" => @image_id, "state" => "downloading", "progress" => 40},
      "cache.stats" => %{
        "t" => 1_800_000_000_000,
        "hosts" => [
          %{
            "host" => "ghcr.io",
            "hits" => 4,
            "misses" => 1,
            "bytes_served" => 100,
            "bytes_stored" => 20
          }
        ],
        "top" => [
          %{"host" => "ghcr.io", "repo" => "actions/runner", "hits" => 4, "bytes_served" => 100}
        ],
        "evictions" => 0,
        "digest_mismatches" => 0
      }
    }
  end

  def command(type), do: Map.fetch!(commands(), type)
  def event(type), do: Map.fetch!(events(), type)
end
