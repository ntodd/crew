defmodule CrewAgent.UnitsTest do
  use ExUnit.Case, async: true

  alias CrewAgent.{Config, HostMetrics, Identity, Net, Ops}
  alias CrewAgent.Driver.Null

  describe "leases (§14.1)" do
    test "lease n is the n-th /30: .1 gateway, .2 guest" do
      assert %{gateway: "10.200.0.5", guest: "10.200.0.6", netmask: "255.255.255.252"} =
               Net.lease(1, "10.200.0.0/16")

      assert %{gateway: "10.200.4.1", guest: "10.200.4.2"} = Net.lease(256, "10.200.0.0/16")
      assert Net.capacity(16) == 16_384
    end

    test "allocate, claim and release" do
      {:ok, pid} = GenServer.start_link(Net, cidr: "10.201.0.0/28")
      a = GenServer.call(pid, {:allocate, "a"})
      assert {:ok, %{index: 1}} = a
      assert {:ok, %{index: 2}} = GenServer.call(pid, {:allocate, "b"})
      assert {:ok, %{index: 3}} = GenServer.call(pid, {:allocate, "c"})
      # A /28 has four /30s; 0 is never used.
      assert {:error, :no_leases} = GenServer.call(pid, {:allocate, "d"})
      assert a == GenServer.call(pid, {:allocate, "a"})
      assert {:error, :taken} = GenServer.call(pid, {:claim, "z", 2})
      :ok = GenServer.call(pid, {:release, "b"})
      assert {:ok, %{index: 2}} = GenServer.call(pid, {:claim, "z", 2})
    end

    test "MACs are locally administered and come from the guest address" do
      assert %{mac: "02:c2:0a:c8:00:06"} = Net.lease(1, "10.200.0.0/16")
    end
  end

  describe "host metrics" do
    test "Linux /proc/meminfo" do
      meminfo =
        "MemTotal:       16384000 kB\nMemAvailable:    8192000 kB\nSwapTotal:  1024000 kB\nSwapFree: 512000 kB\n"

      assert %{total: 16_000, used: 8000, swap_used: 500} = HostMetrics.linux_memory(meminfo)
    end

    test "CPU from two /proc/stat readings" do
      a = HostMetrics.cpu_times("cpu  100 0 100 800 0 0 0 0\n")
      b = HostMetrics.cpu_times("cpu  200 0 200 1400 0 0 0 0\n")
      assert HostMetrics.cpu_percent(a, b) == 25.0
    end

    test "macOS top and vm_stat" do
      assert HostMetrics.parse_top_idle("CPU usage: 3.42% user, 5.41% sys, 91.16% idle") == 8.8

      vm_stat =
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:      1000.\nPages inactive:    1000.\nPages speculative:  48.\n"

      assert HostMetrics.parse_vm_stat_free(vm_stat) == 32
    end

    test "a null box's VM area is all free: its VMs take no disk" do
      config = %{Config.get() | driver: "null"}
      {:ok, caps} = Null.capabilities()
      {sample, _} = HostMetrics.sample(config, nil)
      assert sample.vm_area_free_mib == caps.vm_area_mib
    end

    test "macOS load" do
      assert HostMetrics.parse_loadavg("{ 3.21 2.98 2.75 }\n") == 3.21
    end

    test "df" do
      out =
        "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s1 1000000 400000 600000 40% /\n"

      assert HostMetrics.parse_df(out) == {976, 585}
    end
  end

  describe "the control plane URL (§5.3)" do
    test "wss:// only, ws:// with CREW_DEV" do
      assert :ok = Config.check_url(%Config{url: "wss://crew.ts.net/agent/websocket"})
      assert {:error, _} = Config.check_url(%Config{url: "ws://crew.ts.net/agent/websocket"})

      assert :ok =
               Config.check_url(%Config{url: "ws://localhost:4100/agent/websocket", dev: true})

      assert {:error, _} = Config.check_url(%Config{url: nil})
    end

    test "enrollment goes to the same host over https" do
      assert Identity.enroll_url("wss://crew.ts.net/agent/websocket") ==
               "https://crew.ts.net/api/agents/enroll"

      assert Identity.enroll_url("ws://localhost:4100/agent/websocket") ==
               "http://localhost:4100/api/agents/enroll"
    end
  end

  describe "ops" do
    test "are idempotent by op_id, and a finished one's result is sent again" do
      test = self()

      {:ok, ops} =
        Ops.start_link(
          name: nil,
          handler: fn _ -> send(test, :ran) && :ok end,
          sink: &send(test, {:sink, &1})
        )

      {:ok, cmd} = CrewProtocol.Command.new("box.inventory", %{})

      assert :accepted = Ops.submit(ops, cmd)
      assert_receive {:sink, %{type: "op.result", payload: %{status: "ok"}}}
      assert :duplicate = Ops.submit(ops, cmd)
      assert_receive {:sink, %{type: "op.result"}}
      assert_received :ran
      refute_received :ran
    end

    test "errors carry a code and a message" do
      assert %{payload: %{status: "error", error: %{code: "image_not_ready", message: "x"}}} =
               Ops.result_event(CrewProtocol.uuid(), {:error, "image_not_ready", "x"})
    end
  end
end
