defmodule CrewAgent.ConformanceModeTest do
  @moduledoc """
  Conformance mode (§11.6): the guest runs the image's fixed checks
  instead of the runner, when, and only when, its payload carries a
  `conformance` object. Only the agent puts one there, and only when its
  own config has `CREW_CONFORMANCE=1`.
  """
  use ExUnit.Case, async: false

  import CrewAgent.TestEvents

  alias CrewAgent.{Config, Conformance, Handler, VMs}

  setup do
    attach()
    base = Config.get()
    # A guest that never asks for its payload: the test fetches it.
    Config.put(%{base | null_guest_cmd: "sleep 60"})

    on_exit(fn ->
      Config.put(base)
    end)

    %{base: base}
  end

  defp api, do: "http://127.0.0.1:#{CrewAgent.GuestAPI.port()}"

  defp token_of(vm_id),
    do: File.read!(Path.join(Config.vm_dir(Config.get(), vm_id), "null-token"))

  defp payload_of(cmd) do
    vm_id = cmd.payload.vm_id
    assert :ok = Handler.handle(cmd)
    on_exit(fn -> VMs.stop(vm_id, true, 0) end)

    %{status: 200, body: body} =
      Req.get!(api() <> "/v1/payload", auth: {:bearer, token_of(vm_id)}, retry: false)

    body
  end

  @params %{
    "checks" => ["sizing", "isolation"],
    "targets" => [%{"label" => "host-ssh", "ip" => "192.168.64.34", "port" => 22}]
  }

  test "off (the default): no conformance object, whatever was registered for the VM", %{
    base: base
  } do
    refute base.conformance
    cmd = start_command()
    assert :ok = Conformance.put(cmd.payload.vm_id, @params)

    payload = payload_of(cmd)
    refute Map.has_key?(payload, "conformance")
    assert payload["jit_config"] == cmd.payload.jit_config
  end

  test "on: the VM's registered checks go in its payload, once", %{base: base} do
    Config.put(%{base | null_guest_cmd: "sleep 60", conformance: true})
    cmd = start_command()
    assert :ok = Conformance.put(cmd.payload.vm_id, @params)

    assert payload_of(cmd)["conformance"] == @params
    # Taken at the start: nothing is left registered for the VM.
    assert Conformance.registered(cmd.payload.vm_id) == nil
  end

  test "on, with nothing registered: the default checks", %{base: base} do
    Config.put(%{base | null_guest_cmd: "sleep 60", conformance: true})
    assert %{"conformance" => conformance} = payload_of(start_command())
    assert conformance == Conformance.default()
    assert {:ok, _} = CrewProtocol.Guest.cast_conformance(conformance)
  end

  test "a conformance object that doesn't validate isn't registered" do
    vm_id = CrewProtocol.uuid7()
    assert {:error, _} = Conformance.put(vm_id, %{"checks" => ["sizing"], "script" => "/bin/sh"})
    assert {:error, _} = Conformance.put(vm_id, %{"checks" => ["$(reboot)"]})
    assert Conformance.registered(vm_id) == nil
  end

  test "a vm.start from the control plane can't ask for it" do
    payload = Map.put(start_command().payload |> wire(), "conformance", @params)

    assert {:error, [{"conformance", "is not allowed"}]} =
             CrewProtocol.Command.new("vm.start", payload)
  end

  defp wire(payload) do
    {:ok, cmd} = CrewProtocol.Command.new("vm.start", stringify(payload))
    stringify(cmd.payload)
  end

  defp stringify(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(l) when is_list(l), do: Enum.map(l, &stringify/1)
  defp stringify(a) when is_atom(a) and not is_boolean(a) and not is_nil(a), do: to_string(a)
  defp stringify(v), do: v
end
