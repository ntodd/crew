defmodule CrewAgent.Driver.NullTest do
  # Sets an OS environment variable.
  use ExUnit.Case, async: false

  alias CrewAgent.Driver.Null

  setup do
    on_exit(fn -> System.delete_env("CREW_NULL_GUEST_ARCH") end)
  end

  test "the guest arch can be pinned, so a run looks the same on any host" do
    System.put_env("CREW_NULL_GUEST_ARCH", "arm64")
    assert {:ok, %{guest_arch: "arm64"}} = Null.capabilities()
    System.put_env("CREW_NULL_GUEST_ARCH", "x64")
    assert {:ok, %{guest_arch: "x64"}} = Null.capabilities()
  end

  test "anything else is the host's" do
    System.put_env("CREW_NULL_GUEST_ARCH", "sparc")

    host =
      if :erlang.system_info(:system_architecture) |> to_string() =~ ~r/aarch64|arm/,
        do: "arm64",
        else: "x64"

    assert {:ok, %{guest_arch: ^host}} = Null.capabilities()
  end
end
